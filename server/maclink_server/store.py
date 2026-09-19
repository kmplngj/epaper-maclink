"""Atomic per-display state. Pixels, encoded artifacts and revision commit together."""
import hashlib
import io
import secrets
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image, UnidentifiedImageError


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


class Conflict(Exception):
    pass


class Store:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.path = path
        with self.connect() as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("""CREATE TABLE IF NOT EXISTS displays (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, width INTEGER NOT NULL,
                height INTEGER NOT NULL, token_hash TEXT NOT NULL,
                revision INTEGER NOT NULL DEFAULT 0, digest TEXT, pixels BLOB,
                png BLOB, observed_at TEXT, published_at TEXT, checked_at TEXT,
                delivered_digest TEXT, delivered_at TEXT, last_seen TEXT,
                poll_seconds INTEGER NOT NULL DEFAULT 300,
                downloads INTEGER NOT NULL DEFAULT 0, unchanged INTEGER NOT NULL DEFAULT 0
            )""")
            columns={row['name'] for row in db.execute("PRAGMA table_info(displays)")}
            for name,definition in {
                'schedule_enabled':'INTEGER NOT NULL DEFAULT 0',
                'update_start':'INTEGER NOT NULL DEFAULT 420',
                'update_end':'INTEGER NOT NULL DEFAULT 1320',
                'schedule_timezone':"TEXT NOT NULL DEFAULT 'UTC'",
            }.items():
                if name not in columns:
                    db.execute(f"ALTER TABLE displays ADD COLUMN {name} {definition}")

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=10)
        db.row_factory = sqlite3.Row
        try:
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    def create(self, name: str, width: int, height: int, poll_seconds: int):
        ident, token = secrets.token_hex(8), secrets.token_urlsafe(32)
        with self.connect() as db:
            db.execute("INSERT INTO displays (id,name,width,height,token_hash,poll_seconds) VALUES (?,?,?,?,?,?)",
                       (ident, name, width, height, token_hash(token), poll_seconds))
        return self.get(ident), token

    def get(self, ident: str):
        with self.connect() as db:
            row = db.execute("SELECT * FROM displays WHERE id=?", (ident,)).fetchone()
            return dict(row) if row else None

    def list(self):
        with self.connect() as db:
            return [dict(row) for row in db.execute("SELECT * FROM displays ORDER BY rowid")]

    def update(self, ident: str, name: str, poll_seconds: int):
        with self.connect() as db:
            db.execute("UPDATE displays SET name=?,poll_seconds=? WHERE id=?", (name,poll_seconds,ident))
        return self.get(ident)

    def rotate_token(self, ident: str) -> str:
        token = secrets.token_urlsafe(32)
        with self.connect() as db:
            db.execute("UPDATE displays SET token_hash=? WHERE id=?", (token_hash(token),ident))
        return token

    def update_battery(self, ident, poll_seconds, schedule_enabled, update_start, update_end, schedule_timezone):
        with self.connect() as db:
            db.execute("""UPDATE displays SET poll_seconds=?,schedule_enabled=?,update_start=?,update_end=?,schedule_timezone=? WHERE id=?""",
                       (poll_seconds,int(schedule_enabled),update_start,update_end,schedule_timezone,ident))
        return self.get(ident)

    def publish(self, ident: str, content: bytes, revision: int, observed_at: str):
        row = self.get(ident)
        if row is None:
            raise KeyError(ident)
        try:
            with Image.open(io.BytesIO(content)) as original:
                if original.size != (row['width'], row['height']):
                    raise ValueError(f"Image must be {row['width']} × {row['height']} pixels")
                original.load()
                rgba = original.convert("RGBA")
                background = Image.new("RGBA", original.size, "white")
                background.alpha_composite(rgba)
                # Fixed threshold: native renderer already provides monochrome pixels.
                mono = background.convert("L").point(lambda x: 255 if x >= 128 else 0, mode="1")
                pixels = mono.tobytes()
                descriptor = f"mono1:white=1:msb:{row['width']}:{row['height']}:".encode()
                digest = hashlib.sha256(descriptor + pixels).hexdigest()
                output = io.BytesIO()
                mono.save(output, format="PNG", optimize=False)
                png = output.getvalue()
        except (UnidentifiedImageError, OSError, Image.DecompressionBombError) as exc:
            raise ValueError("Invalid image") from exc
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            current = dict(db.execute("SELECT * FROM displays WHERE id=?", (ident,)).fetchone())
            if revision < current['revision'] or (revision == current['revision'] and digest != current['digest']):
                raise Conflict("A newer image is already published; reload server status and retry")
            changed = pixels != current['pixels']
            stamp = now()
            if changed:
                db.execute("""UPDATE displays SET revision=?,digest=?,pixels=?,png=?,observed_at=?,
                    published_at=?,checked_at=? WHERE id=?""",
                    (revision,digest,pixels,png,observed_at,stamp,stamp,ident))
            else:
                # Preserve identical encoded bytes and their validator.
                db.execute("UPDATE displays SET revision=?,observed_at=?,checked_at=? WHERE id=?",
                           (revision,observed_at,stamp,ident))
            committed = dict(db.execute("SELECT * FROM displays WHERE id=?", (ident,)).fetchone())
        return committed, changed

    def record_get(self, ident: str, unchanged: bool):
        column = "unchanged" if unchanged else "downloads"
        with self.connect() as db:
            db.execute(f"UPDATE displays SET {column}={column}+1,last_seen=? WHERE id=?", (now(),ident))

    def record_seen(self, ident: str):
        with self.connect() as db:
            db.execute("UPDATE displays SET last_seen=? WHERE id=?",(now(),ident))

    def acknowledge(self, ident: str, digest: str):
        with self.connect() as db:
            result = db.execute("UPDATE displays SET delivered_digest=?,delivered_at=?,last_seen=? WHERE id=? AND digest=?",
                                (digest,now(),now(),ident,digest))
            if result.rowcount != 1:
                raise Conflict("Acknowledgment is for an obsolete frame")


def public(row):
    result={key:value for key,value in row.items() if key not in {'token_hash','pixels','png'}}
    result['schedule_enabled']=bool(result['schedule_enabled'])
    return result
