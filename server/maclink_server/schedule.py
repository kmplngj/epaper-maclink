"""Daily local-time windows converted to UTC for the small display client."""
from datetime import datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo


def boundary(day, minute, zone, *, ending=False):
    wall = datetime.combine(day, time(minute // 60, minute % 60))
    # Advance nonexistent spring-forward times to the first valid minute.
    # On fall-back days use the first opening and last closing occurrence.
    for _ in range(181):
        value = wall.replace(tzinfo=zone, fold=1 if ending else 0)
        if value.astimezone(timezone.utc).astimezone(zone).replace(tzinfo=None) == wall:
            return int(value.timestamp())
        wall += timedelta(minutes=1)
    raise ValueError("Could not resolve the local schedule boundary")


def plan(row, instant=None):
    instant = instant or datetime.now(timezone.utc)
    stamp = int(instant.timestamp())
    interval = row['poll_seconds']
    enabled = bool(row['schedule_enabled'])
    windows = []
    expires = stamp + 30 * 86400
    if enabled:
        zone = ZoneInfo(row['schedule_timezone'])
        today = instant.astimezone(zone).date()
        start, end = row['update_start'], row['update_end']
        for offset in range(-1, 33):
            day = today + timedelta(days=offset)
            opening = boundary(day, start, zone)
            closing = boundary(day + timedelta(days=int(end <= start)), end, zone, ending=True)
            if closing > max(stamp, opening):
                windows.append((opening, closing))
    active = not enabled or any(start <= stamp < end for start, end in windows)
    target = stamp + interval if active else stamp
    if enabled:
        target = next((max(target, start) for start, end in windows if target < end), expires)
    headers = {
        'X-Server-Time': str(stamp),
        'X-Update-Seconds': str(interval),
        'X-Poll-Seconds': str(max(1, target - stamp)),
        'X-Schedule-Until': str(expires),
        'X-Update-Windows': ','.join(f'{start}-{end}' for start, end in windows) if enabled else '*',
    }
    return active, headers
