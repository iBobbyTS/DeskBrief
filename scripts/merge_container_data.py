#!/usr/bin/env python3
"""Merge legacy sandbox-container DeskBrief data into non-sandbox storage.

The command is a dry run unless --apply is supplied. During an applied merge it
backs up the destination support directory before changing the database or
copying screenshots.
"""

from __future__ import annotations

import argparse
import filecmp
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Iterable, Sequence


DATABASE_NAME = "desk-brief.sqlite"
EXPECTED_SCHEMA_VERSION = 1
DEFAULT_SOURCE_DIRECTORY = (
    Path.home()
    / "Library/Containers/com.iBobby.DeskBrief2/Data/Library/Application Support/DeskBrief"
)
DEFAULT_DESTINATION_DIRECTORY = Path.home() / "Library/Application Support/DeskBrief"

EXPECTED_COLUMNS: dict[str, tuple[str, ...]] = {
    "category_rules": ("id", "name", "description", "color_hex", "sort_order"),
    "analysis_runs": (
        "id",
        "status",
        "model_name",
        "total_items",
        "success_count",
        "failure_count",
        "input_mean_tokens",
        "input_max_tokens",
        "output_mean_tokens",
        "output_max_tokens",
        "average_item_duration_seconds",
        "error_message",
        "created_at",
    ),
    "summary_runs": (
        "id",
        "analysis_run_id",
        "status",
        "model_name",
        "total_items",
        "success_count",
        "failure_count",
        "input_mean_tokens",
        "input_max_tokens",
        "output_mean_tokens",
        "output_max_tokens",
        "average_item_duration_seconds",
        "error_message",
        "created_at",
    ),
    "analysis_results": (
        "id",
        "captured_at",
        "category_name",
        "summary_text",
        "duration_minutes_snapshot",
    ),
    "daily_work_block_summaries": (
        "id",
        "category_name",
        "start_at",
        "end_at",
        "summary_text",
    ),
    "daily_reports": (
        "id",
        "day_start",
        "daily_summary_text",
        "category_summaries_json",
        "is_temporary",
    ),
    "app_logs": ("id", "created_at", "level", "source", "message"),
}


class MergeError(RuntimeError):
    """Raised when the merge cannot proceed safely."""


@dataclass
class ItemStats:
    inserted: int = 0
    duplicate: int = 0
    conflicts: int = 0


@dataclass
class MergeReport:
    tables: dict[str, ItemStats] = field(default_factory=dict)
    screenshots: ItemStats = field(default_factory=ItemStats)

    def table(self, name: str) -> ItemStats:
        return self.tables.setdefault(name, ItemStats())


def quote_identifier(identifier: str) -> str:
    return '"' + identifier.replace('"', '""') + '"'


def connect_read_only(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(f"{path.resolve().as_uri()}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    return connection


def connect_writable(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(path, isolation_level=None)
    connection.row_factory = sqlite3.Row
    return connection


def ensure_plaintext_sqlite(path: Path) -> None:
    if not path.is_file():
        raise MergeError(f"database does not exist: {path}")
    with path.open("rb") as database_file:
        header = database_file.read(16)
    if header != b"SQLite format 3\x00":
        raise MergeError(
            f"database is not plaintext SQLite: {path}. "
            "Disable DeskBrief database encryption or export a plaintext copy first."
        )


def table_columns(connection: sqlite3.Connection, table: str) -> tuple[str, ...]:
    rows = connection.execute(f"PRAGMA table_info({quote_identifier(table)})").fetchall()
    return tuple(str(row["name"]) for row in rows)


def schema_signature(
    connection: sqlite3.Connection,
) -> dict[str, tuple[tuple[object, ...], ...]]:
    signature: dict[str, tuple[tuple[object, ...], ...]] = {}
    for table in EXPECTED_COLUMNS:
        rows = connection.execute(
            f"PRAGMA table_info({quote_identifier(table)})"
        ).fetchall()
        signature[table] = tuple(
            (
                row["name"],
                row["type"],
                row["notnull"],
                row["dflt_value"],
                row["pk"],
            )
            for row in rows
        )
    return signature


def validate_database(connection: sqlite3.Connection, label: str) -> None:
    version = int(connection.execute("PRAGMA user_version").fetchone()[0])
    if version != EXPECTED_SCHEMA_VERSION:
        raise MergeError(
            f"{label} database schema version is {version}; "
            f"expected {EXPECTED_SCHEMA_VERSION}"
        )

    integrity = str(connection.execute("PRAGMA integrity_check").fetchone()[0])
    if integrity != "ok":
        raise MergeError(f"{label} database integrity check failed: {integrity}")

    foreign_key_errors = connection.execute("PRAGMA foreign_key_check").fetchall()
    if foreign_key_errors:
        raise MergeError(
            f"{label} database foreign-key check failed: {foreign_key_errors!r}"
        )

    for table, expected in EXPECTED_COLUMNS.items():
        actual = table_columns(connection, table)
        if len(actual) != len(expected) or set(actual) != set(expected):
            raise MergeError(
                f"{label} table {table} has unexpected columns: "
                f"{actual!r}; expected {expected!r}"
            )


def row_values(row: sqlite3.Row, columns: Sequence[str]) -> tuple[object, ...]:
    return tuple(row[column] for column in columns)


def insert_row(
    connection: sqlite3.Connection,
    table: str,
    columns: Sequence[str],
    values: Sequence[object],
) -> int:
    column_sql = ", ".join(quote_identifier(column) for column in columns)
    placeholders = ", ".join("?" for _ in columns)
    cursor = connection.execute(
        f"INSERT INTO {quote_identifier(table)} ({column_sql}) VALUES ({placeholders})",
        tuple(values),
    )
    return int(cursor.lastrowid)


def merge_remapped_runs(
    source: sqlite3.Connection,
    destination: sqlite3.Connection,
    report: MergeReport,
) -> dict[int, int]:
    table = "analysis_runs"
    columns = EXPECTED_COLUMNS[table]
    content_columns = columns[1:]
    existing = {
        row_values(row, content_columns): int(row["id"])
        for row in destination.execute(f"SELECT * FROM {quote_identifier(table)}")
    }
    id_map: dict[int, int] = {}
    stats = report.table(table)

    for row in source.execute(f"SELECT * FROM {quote_identifier(table)} ORDER BY id"):
        source_id = int(row["id"])
        content = row_values(row, content_columns)
        if content in existing:
            id_map[source_id] = existing[content]
            stats.duplicate += 1
            continue
        destination_id = insert_row(destination, table, content_columns, content)
        existing[content] = destination_id
        id_map[source_id] = destination_id
        stats.inserted += 1

    return id_map


def merge_remapped_summary_runs(
    source: sqlite3.Connection,
    destination: sqlite3.Connection,
    analysis_run_id_map: dict[int, int],
    report: MergeReport,
) -> None:
    table = "summary_runs"
    columns = EXPECTED_COLUMNS[table]
    content_columns = columns[1:]
    existing = {
        row_values(row, content_columns): int(row["id"])
        for row in destination.execute(f"SELECT * FROM {quote_identifier(table)}")
    }
    stats = report.table(table)

    for row in source.execute(f"SELECT * FROM {quote_identifier(table)} ORDER BY id"):
        source_analysis_run_id = row["analysis_run_id"]
        mapped_analysis_run_id = None
        if source_analysis_run_id is not None:
            try:
                mapped_analysis_run_id = analysis_run_id_map[int(source_analysis_run_id)]
            except KeyError as error:
                raise MergeError(
                    "summary_runs references a missing source analysis run: "
                    f"{source_analysis_run_id}"
                ) from error

        content = list(row_values(row, content_columns))
        content[content_columns.index("analysis_run_id")] = mapped_analysis_run_id
        content_tuple = tuple(content)
        if content_tuple in existing:
            stats.duplicate += 1
            continue
        destination_id = insert_row(destination, table, content_columns, content_tuple)
        existing[content_tuple] = destination_id
        stats.inserted += 1


def merge_by_natural_key(
    source: sqlite3.Connection,
    destination: sqlite3.Connection,
    report: MergeReport,
    table: str,
    key_columns: Sequence[str],
    *,
    omit_id_on_insert: bool,
) -> None:
    all_columns = EXPECTED_COLUMNS[table]
    insert_columns = all_columns[1:] if omit_id_on_insert else all_columns
    payload_columns = tuple(
        column
        for column in all_columns
        if column not in key_columns
        and not (omit_id_on_insert and column == "id")
    )
    existing: dict[tuple[object, ...], tuple[object, ...]] = {}
    for row in destination.execute(f"SELECT * FROM {quote_identifier(table)}"):
        existing[row_values(row, key_columns)] = row_values(row, payload_columns)

    stats = report.table(table)
    for row in source.execute(f"SELECT * FROM {quote_identifier(table)}"):
        key = row_values(row, key_columns)
        payload = row_values(row, payload_columns)
        if key in existing:
            if existing[key] == payload:
                stats.duplicate += 1
            else:
                stats.conflicts += 1
            continue
        insert_row(destination, table, insert_columns, row_values(row, insert_columns))
        existing[key] = payload
        stats.inserted += 1


def merge_databases(source_path: Path, destination_path: Path) -> MergeReport:
    ensure_plaintext_sqlite(source_path)
    ensure_plaintext_sqlite(destination_path)
    source = connect_read_only(source_path)
    destination = connect_writable(destination_path)
    report = MergeReport()

    try:
        validate_database(source, "source")
        validate_database(destination, "destination")
        if schema_signature(source) != schema_signature(destination):
            raise MergeError("source and destination database schemas do not match")
        destination.execute("PRAGMA foreign_keys = ON")
        destination.execute("BEGIN IMMEDIATE")
        try:
            merge_by_natural_key(
                source,
                destination,
                report,
                "category_rules",
                ("id",),
                omit_id_on_insert=False,
            )
            analysis_run_id_map = merge_remapped_runs(source, destination, report)
            merge_remapped_summary_runs(
                source,
                destination,
                analysis_run_id_map,
                report,
            )
            merge_by_natural_key(
                source,
                destination,
                report,
                "analysis_results",
                ("captured_at",),
                omit_id_on_insert=True,
            )
            merge_by_natural_key(
                source,
                destination,
                report,
                "daily_work_block_summaries",
                ("start_at", "end_at"),
                omit_id_on_insert=True,
            )
            merge_by_natural_key(
                source,
                destination,
                report,
                "daily_reports",
                ("day_start",),
                omit_id_on_insert=True,
            )
            merge_by_natural_key(
                source,
                destination,
                report,
                "app_logs",
                ("id",),
                omit_id_on_insert=False,
            )

            foreign_key_errors = destination.execute("PRAGMA foreign_key_check").fetchall()
            if foreign_key_errors:
                raise MergeError(
                    f"destination foreign-key check failed: {foreign_key_errors!r}"
                )
            integrity = str(destination.execute("PRAGMA integrity_check").fetchone()[0])
            if integrity != "ok":
                raise MergeError(
                    f"destination integrity check failed after merge: {integrity}"
                )
            destination.execute("COMMIT")
        except Exception:
            destination.execute("ROLLBACK")
            raise
    finally:
        destination.close()
        source.close()

    return report


SCREENSHOT_NAME_PATTERN = re.compile(
    r"^(?P<timestamp>\d{8}-\d{4})(?P<middle>.*?)(?P<interval>-i\d+)?$"
)


def conflict_filename(path: Path, number: int) -> str:
    match = SCREENSHOT_NAME_PATTERN.match(path.stem)
    if match:
        timestamp = match.group("timestamp")
        middle = match.group("middle") or ""
        interval = match.group("interval") or ""
        return f"{timestamp}{middle}-container-{number}{interval}{path.suffix}"
    return f"{path.stem}-container-{number}{path.suffix}"


def iter_files(directory: Path) -> Iterable[Path]:
    if not directory.exists():
        return ()
    return (
        path
        for path in sorted(directory.rglob("*"))
        if path.is_file()
        and not any(part.startswith(".") for part in path.relative_to(directory).parts)
    )


def merge_screenshots(
    source_directory: Path,
    destination_directory: Path,
    *,
    apply: bool,
) -> ItemStats:
    stats = ItemStats()
    if not source_directory.exists():
        return stats

    for source_file in iter_files(source_directory):
        relative_path = source_file.relative_to(source_directory)
        destination_file = destination_directory / relative_path
        if not destination_file.exists():
            stats.inserted += 1
            if apply:
                destination_file.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source_file, destination_file)
            continue

        if filecmp.cmp(source_file, destination_file, shallow=False):
            stats.duplicate += 1
            continue

        number = 1
        while True:
            renamed_file = destination_file.with_name(
                conflict_filename(destination_file, number)
            )
            if not renamed_file.exists():
                break
            if filecmp.cmp(source_file, renamed_file, shallow=False):
                stats.duplicate += 1
                renamed_file = None
                break
            number += 1

        if renamed_file is not None:
            stats.conflicts += 1
            stats.inserted += 1
            if apply:
                renamed_file.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source_file, renamed_file)

    return stats


def ensure_app_is_stopped() -> None:
    result = subprocess.run(
        ["pgrep", "-x", "DeskBrief"],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        process_ids = ", ".join(result.stdout.split())
        raise MergeError(
            f"DeskBrief is running (PID: {process_ids}). Quit the app before merging."
        )
    if result.returncode not in (0, 1):
        raise MergeError(f"could not check whether DeskBrief is running: {result.stderr}")


def next_available_path(path: Path) -> Path:
    if not path.exists():
        return path
    number = 2
    while True:
        candidate = path.with_name(f"{path.name}-{number}")
        if not candidate.exists():
            return candidate
        number += 1


def default_backup_path() -> Path:
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return next_available_path(
        Path.home() / "Desktop" / f"DeskBrief-merge-backup-{timestamp}"
    )


def backup_destination(destination_directory: Path, backup_directory: Path) -> None:
    if backup_directory.exists():
        raise MergeError(f"backup directory already exists: {backup_directory}")
    backup_directory.mkdir(parents=True)

    excluded_database_files = {
        DATABASE_NAME,
        f"{DATABASE_NAME}-wal",
        f"{DATABASE_NAME}-shm",
        f"{DATABASE_NAME}-journal",
    }
    for child in destination_directory.iterdir():
        if child.name in excluded_database_files:
            continue
        destination = backup_directory / child.name
        if child.is_dir():
            shutil.copytree(child, destination)
        else:
            shutil.copy2(child, destination)

    source_connection = connect_read_only(destination_directory / DATABASE_NAME)
    backup_connection = sqlite3.connect(backup_directory / DATABASE_NAME)
    try:
        source_connection.backup(backup_connection)
    finally:
        backup_connection.close()
        source_connection.close()

    validated_backup = connect_read_only(backup_directory / DATABASE_NAME)
    try:
        validate_database(validated_backup, "backup")
    finally:
        validated_backup.close()


def database_dry_run(source_path: Path, destination_path: Path) -> MergeReport:
    with tempfile.TemporaryDirectory(prefix="deskbrief-merge-") as temporary_directory:
        temporary_database = Path(temporary_directory) / DATABASE_NAME
        source_connection = connect_read_only(destination_path)
        temporary_connection = sqlite3.connect(temporary_database)
        try:
            source_connection.backup(temporary_connection)
        finally:
            temporary_connection.close()
            source_connection.close()
        return merge_databases(source_path, temporary_database)


def print_report(report: MergeReport, *, applied: bool) -> None:
    mode = "APPLIED" if applied else "DRY RUN"
    print(f"\nDeskBrief container merge: {mode}")
    for table in EXPECTED_COLUMNS:
        stats = report.table(table)
        print(
            f"  {table}: inserted={stats.inserted}, "
            f"duplicate={stats.duplicate}, conflicts_kept_destination={stats.conflicts}"
        )
    screenshots = report.screenshots
    print(
        "  screenshots: "
        f"copied={screenshots.inserted}, duplicate={screenshots.duplicate}, "
        f"renamed_conflicts={screenshots.conflicts}"
    )


def parse_arguments(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Merge DeskBrief's sandbox-container database and screenshots into "
            "the non-sandbox Application Support directory."
        )
    )
    parser.add_argument(
        "--source-dir",
        type=Path,
        default=DEFAULT_SOURCE_DIRECTORY,
        help=f"container Application Support directory (default: {DEFAULT_SOURCE_DIRECTORY})",
    )
    parser.add_argument(
        "--destination-dir",
        type=Path,
        default=DEFAULT_DESTINATION_DIRECTORY,
        help=(
            "non-container Application Support directory "
            f"(default: {DEFAULT_DESTINATION_DIRECTORY})"
        ),
    )
    parser.add_argument(
        "--backup-dir",
        type=Path,
        help="backup directory used with --apply (default: timestamped folder on Desktop)",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="perform the merge; without this flag the command is read-only",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    source_directory = arguments.source_dir.expanduser().resolve()
    destination_directory = arguments.destination_dir.expanduser().resolve()
    source_database = source_directory / DATABASE_NAME
    destination_database = destination_directory / DATABASE_NAME

    try:
        if source_directory == destination_directory:
            raise MergeError("source and destination directories must be different")
        if not source_directory.is_dir():
            raise MergeError(f"source directory does not exist: {source_directory}")
        if not destination_directory.is_dir():
            raise MergeError(
                f"destination directory does not exist: {destination_directory}"
            )
        ensure_app_is_stopped()
        ensure_plaintext_sqlite(source_database)
        ensure_plaintext_sqlite(destination_database)

        if arguments.apply:
            backup_directory = (
                arguments.backup_dir.expanduser().resolve()
                if arguments.backup_dir
                else default_backup_path()
            )
            if backup_directory == destination_directory or destination_directory in backup_directory.parents:
                raise MergeError(
                    "backup directory must not be inside the destination support directory"
                )
            backup_destination(destination_directory, backup_directory)
            print(f"Backup: {backup_directory}")
            report = merge_databases(source_database, destination_database)
            report.screenshots = merge_screenshots(
                source_directory / "screenshots",
                destination_directory / "screenshots",
                apply=True,
            )
        else:
            report = database_dry_run(source_database, destination_database)
            report.screenshots = merge_screenshots(
                source_directory / "screenshots",
                destination_directory / "screenshots",
                apply=False,
            )

        print_report(report, applied=arguments.apply)
        if not arguments.apply:
            print("\nNo files were changed. Run again with --apply to perform the merge.")
        return 0
    except (MergeError, OSError, sqlite3.Error) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
