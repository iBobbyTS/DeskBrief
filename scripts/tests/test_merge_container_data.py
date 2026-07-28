from __future__ import annotations

import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS_DIRECTORY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS_DIRECTORY))

from merge_container_data import (  # noqa: E402
    backup_destination,
    conflict_filename,
    merge_databases,
    merge_screenshots,
)


SCHEMA = """
PRAGMA user_version = 1;
PRAGMA foreign_keys = ON;

CREATE TABLE category_rules (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT NOT NULL,
    color_hex TEXT NOT NULL,
    sort_order INTEGER NOT NULL
);
CREATE TABLE analysis_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    status TEXT NOT NULL,
    model_name TEXT NOT NULL,
    total_items INTEGER NOT NULL,
    success_count INTEGER NOT NULL DEFAULT 0,
    failure_count INTEGER NOT NULL DEFAULT 0,
    average_item_duration_seconds DOUBLE,
    error_message TEXT,
    created_at DOUBLE NOT NULL,
    input_mean_tokens DOUBLE,
    input_max_tokens INTEGER,
    output_mean_tokens DOUBLE,
    output_max_tokens INTEGER,
    CONSTRAINT analysis_runs_column_order_compatibility CHECK (1)
);
CREATE TABLE summary_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    analysis_run_id INTEGER REFERENCES analysis_runs(id),
    status TEXT NOT NULL,
    model_name TEXT NOT NULL,
    total_items INTEGER NOT NULL,
    success_count INTEGER NOT NULL DEFAULT 0,
    failure_count INTEGER NOT NULL DEFAULT 0,
    input_mean_tokens DOUBLE,
    input_max_tokens INTEGER,
    output_mean_tokens DOUBLE,
    output_max_tokens INTEGER,
    average_item_duration_seconds DOUBLE,
    error_message TEXT,
    created_at DOUBLE NOT NULL
);
CREATE TABLE analysis_results (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    captured_at DOUBLE NOT NULL,
    category_name TEXT,
    summary_text TEXT,
    duration_minutes_snapshot INTEGER NOT NULL
);
CREATE UNIQUE INDEX idx_analysis_results_captured_at_unique
    ON analysis_results(captured_at);
CREATE TABLE daily_work_block_summaries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    category_name TEXT NOT NULL,
    start_at DOUBLE NOT NULL,
    end_at DOUBLE NOT NULL,
    summary_text TEXT NOT NULL,
    UNIQUE(start_at, end_at)
);
CREATE TABLE daily_reports (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    day_start DOUBLE NOT NULL UNIQUE,
    daily_summary_text TEXT NOT NULL,
    category_summaries_json TEXT NOT NULL,
    is_temporary INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE app_logs (
    id TEXT PRIMARY KEY,
    created_at DOUBLE NOT NULL,
    level TEXT NOT NULL,
    source TEXT NOT NULL,
    message TEXT NOT NULL
);
"""


ANALYSIS_RUN_INSERT = """
INSERT INTO analysis_runs (
    id, status, model_name, total_items, success_count, failure_count,
    input_mean_tokens, input_max_tokens, output_mean_tokens, output_max_tokens,
    average_item_duration_seconds, error_message, created_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
"""


def create_database(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(path)
    connection.executescript(SCHEMA)
    return connection


class DatabaseMergeTests(unittest.TestCase):
    def test_merge_remaps_conflicting_ids_and_keeps_destination_payloads(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source_path = root / "source.sqlite"
            destination_path = root / "destination.sqlite"
            source = create_database(source_path)
            destination = create_database(destination_path)

            shared_run = (
                1,
                "succeeded",
                "shared-model",
                1,
                1,
                0,
                None,
                None,
                None,
                None,
                1.0,
                None,
                100.0,
            )
            destination_run = (
                2,
                "succeeded",
                "destination-model",
                1,
                1,
                0,
                None,
                None,
                None,
                None,
                2.0,
                None,
                200.0,
            )
            source_run = (
                2,
                "succeeded",
                "source-model",
                2,
                2,
                0,
                None,
                None,
                None,
                None,
                3.0,
                None,
                300.0,
            )
            for connection in (source, destination):
                connection.execute(ANALYSIS_RUN_INSERT, shared_run)
            destination.execute(ANALYSIS_RUN_INSERT, destination_run)
            source.execute(ANALYSIS_RUN_INSERT, source_run)

            source.execute(
                """
                INSERT INTO summary_runs (
                    id, analysis_run_id, status, model_name, total_items,
                    success_count, failure_count, created_at
                ) VALUES (1, 2, 'succeeded', 'summary-source', 1, 1, 0, 310.0)
                """
            )
            destination.execute(
                """
                INSERT INTO summary_runs (
                    id, analysis_run_id, status, model_name, total_items,
                    success_count, failure_count, created_at
                ) VALUES (1, 2, 'succeeded', 'summary-destination', 1, 1, 0, 210.0)
                """
            )

            source.execute(
                "INSERT INTO category_rules VALUES ('shared', 'Source', 'S', '#111111', 1)"
            )
            destination.execute(
                "INSERT INTO category_rules VALUES ('shared', 'Destination', 'D', '#222222', 1)"
            )
            source.execute(
                "INSERT INTO category_rules VALUES ('source-only', 'New', 'N', '#333333', 2)"
            )

            source.execute(
                "INSERT INTO analysis_results VALUES (1, 1000.0, 'Source', 'conflict', 10)"
            )
            destination.execute(
                "INSERT INTO analysis_results VALUES (1, 1000.0, 'Destination', 'keep', 5)"
            )
            source.execute(
                "INSERT INTO analysis_results VALUES (2, 2000.0, 'Source', 'new', 10)"
            )

            source.execute(
                """
                INSERT INTO daily_work_block_summaries
                VALUES (1, 'Source', 10.0, 20.0, 'new block')
                """
            )
            source.execute(
                "INSERT INTO daily_reports VALUES (1, 100.0, 'source', '{}', 0)"
            )
            destination.execute(
                "INSERT INTO daily_reports VALUES (1, 100.0, 'destination', '{}', 0)"
            )
            source.execute(
                "INSERT INTO app_logs VALUES ('log-1', 1.0, 'log', 'test', 'new')"
            )

            source.commit()
            destination.commit()
            source.close()
            destination.close()

            report = merge_databases(source_path, destination_path)

            merged = sqlite3.connect(destination_path)
            merged.row_factory = sqlite3.Row
            try:
                source_run_row = merged.execute(
                    "SELECT * FROM analysis_runs WHERE model_name = 'source-model'"
                ).fetchone()
                self.assertIsNotNone(source_run_row)
                self.assertNotEqual(source_run_row["id"], 2)

                source_summary = merged.execute(
                    "SELECT * FROM summary_runs WHERE model_name = 'summary-source'"
                ).fetchone()
                self.assertEqual(
                    source_summary["analysis_run_id"],
                    source_run_row["id"],
                )
                self.assertEqual(
                    merged.execute(
                        "SELECT category_name FROM analysis_results WHERE captured_at = 1000.0"
                    ).fetchone()[0],
                    "Destination",
                )
                self.assertEqual(
                    merged.execute(
                        "SELECT count(*) FROM analysis_results WHERE captured_at = 2000.0"
                    ).fetchone()[0],
                    1,
                )
                self.assertEqual(
                    merged.execute(
                        "SELECT daily_summary_text FROM daily_reports WHERE day_start = 100.0"
                    ).fetchone()[0],
                    "destination",
                )
                self.assertEqual(
                    merged.execute(
                        "SELECT count(*) FROM category_rules WHERE id = 'source-only'"
                    ).fetchone()[0],
                    1,
                )
                self.assertEqual(
                    merged.execute("PRAGMA foreign_key_check").fetchall(),
                    [],
                )
            finally:
                merged.close()

            self.assertEqual(report.table("analysis_runs").inserted, 1)
            self.assertEqual(report.table("analysis_runs").duplicate, 1)
            self.assertEqual(report.table("analysis_results").conflicts, 1)
            self.assertEqual(report.table("daily_reports").conflicts, 1)
            self.assertEqual(report.table("category_rules").conflicts, 1)


class ScreenshotMergeTests(unittest.TestCase):
    def test_conflicting_screenshot_is_renamed_without_losing_interval(self) -> None:
        self.assertEqual(
            conflict_filename(Path("20260727-1127-i10.jpg"), 1),
            "20260727-1127-container-1-i10.jpg",
        )

    def test_dry_run_and_apply_preserve_both_conflicting_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "source"
            destination = root / "destination"
            source.mkdir()
            destination.mkdir()
            (source / "20260727-1127-i10.jpg").write_bytes(b"source")
            (destination / "20260727-1127-i10.jpg").write_bytes(b"destination")
            (source / "20260727-1137-i10.jpg").write_bytes(b"new")
            (source / ".DS_Store").write_bytes(b"ignored")

            dry_run = merge_screenshots(source, destination, apply=False)
            self.assertEqual(dry_run.inserted, 2)
            self.assertEqual(dry_run.conflicts, 1)
            self.assertEqual(dry_run.duplicate, 0)
            self.assertFalse(
                (destination / "20260727-1127-container-1-i10.jpg").exists()
            )

            applied = merge_screenshots(source, destination, apply=True)
            self.assertEqual(applied.inserted, 2)
            self.assertEqual(
                (destination / "20260727-1127-i10.jpg").read_bytes(),
                b"destination",
            )
            self.assertEqual(
                (destination / "20260727-1127-container-1-i10.jpg").read_bytes(),
                b"source",
            )
            self.assertEqual(
                (destination / "20260727-1137-i10.jpg").read_bytes(),
                b"new",
            )
            self.assertFalse((destination / ".DS_Store").exists())


class BackupTests(unittest.TestCase):
    def test_backup_contains_consistent_database_and_support_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            support = root / "support"
            backup = root / "backup"
            support.mkdir()
            database = create_database(support / "desk-brief.sqlite")
            database.execute(
                "INSERT INTO app_logs VALUES ('log-1', 1.0, 'log', 'test', 'saved')"
            )
            database.commit()
            database.close()
            screenshots = support / "screenshots"
            screenshots.mkdir()
            (screenshots / "20260727-1137-i10.jpg").write_bytes(b"image")
            (support / "desk-brief.sqlite-shm").write_bytes(b"stale-sidecar")

            backup_destination(support, backup)

            backed_up = sqlite3.connect(backup / "desk-brief.sqlite")
            try:
                self.assertEqual(
                    backed_up.execute("SELECT message FROM app_logs").fetchone()[0],
                    "saved",
                )
                self.assertEqual(
                    backed_up.execute("PRAGMA integrity_check").fetchone()[0],
                    "ok",
                )
            finally:
                backed_up.close()
            self.assertEqual(
                (backup / "screenshots/20260727-1137-i10.jpg").read_bytes(),
                b"image",
            )
            self.assertFalse((backup / "desk-brief.sqlite-shm").exists())


if __name__ == "__main__":
    unittest.main()
