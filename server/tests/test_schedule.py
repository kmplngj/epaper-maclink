from datetime import datetime, timezone
import sqlite3
from unittest.mock import patch

from fastapi.testclient import TestClient

from maclink_server.app import create_app
from maclink_server.schedule import boundary, plan
from maclink_server.store import Store
from zoneinfo import ZoneInfo
from test_api import ADMIN, auth, create, publish, png


def config(**extra):
    return dict(poll_seconds=1800,schedule_enabled=True,update_start=420,update_end=1320,schedule_timezone="Europe/Berlin") | extra


def at(value):return datetime.fromisoformat(value).astimezone(timezone.utc)

def test_daily_window_edges_and_interval_crossing_close():
    row=config()
    active,headers=plan(row,at('2026-09-13T06:59:00+02:00'))
    assert not active and headers['X-Poll-Seconds']=='60'
    assert plan(row,at('2026-09-13T07:00:00+02:00'))[0]
    active,headers=plan(row,at('2026-09-13T21:50:00+02:00'))
    assert active and int(headers['X-Poll-Seconds'])==9*3600+10*60
    assert not plan(row,at('2026-09-13T22:00:00+02:00'))[0]
    assert len(headers['X-Update-Windows'].split(','))<=34


def test_overnight_and_disabled_schedule():
    row=config(update_start=22*60,update_end=6*60)
    assert plan(row,at('2026-09-13T23:00:00+02:00'))[0]
    assert plan(row,at('2026-09-14T05:59:00+02:00'))[0]
    active,headers=plan(row,at('2026-09-14T06:00:00+02:00'))
    assert not active and int(headers['X-Poll-Seconds'])==16*3600
    active,headers=plan(config(schedule_enabled=False),at('2026-09-14T03:00:00+02:00'))
    assert active and headers['X-Update-Windows']=='*' and headers['X-Poll-Seconds']=='1800'


def test_daylight_saving_and_nonexistent_clock_times():
    row=config()
    _,spring=plan(row,at('2026-03-28T22:00:00+01:00'))
    _,autumn=plan(row,at('2026-10-24T22:00:00+02:00'))
    assert int(spring['X-Poll-Seconds'])==8*3600
    assert int(autumn['X-Poll-Seconds'])==10*3600
    day=at('2026-03-29T00:00:00+01:00').astimezone(ZoneInfo('Europe/Berlin')).date()
    assert boundary(day,150,ZoneInfo('Europe/Berlin'))==int(at('2026-03-29T03:00:00+02:00').timestamp())


def test_api_policy_on_200_304_204_and_no_image(tmp_path):
    store=Store(tmp_path/'db.sqlite');client=TestClient(create_app(store,ADMIN))
    first,second=create(client),create(client,'Other')
    ident=first['display']['id'];url=f'/v1/displays/{ident}'
    assert client.patch(url+'/battery',json=config(),headers=auth(first['device_token'])).status_code==401
    assert client.patch(url+'/battery',json=config(),headers=auth()).status_code==200
    assert store.get(second['display']['id'])['poll_seconds']==300
    assert client.patch(url+'/battery',json=config(schedule_timezone='Not/AZone'),headers=auth()).status_code==422
    assert client.patch(url+'/battery',json=config(update_end=420),headers=auth()).status_code==422
    from maclink_server import app as api
    real_plan=plan
    with patch.object(api,'plan',lambda row:real_plan(row,at('2026-09-13T12:00:00+02:00'))):
        missing=client.get(url+'/frame',headers=auth())
        assert missing.status_code==404 and missing.headers['X-Update-Seconds']=='1800'
        publish(client,ident,png(),1)
        first_frame=client.get(url+'/frame',headers=auth())
        assert first_frame.status_code==200 and first_frame.headers['X-Update-Seconds']=='1800'
        cached=client.get(url+'/frame',headers=auth()|{'If-None-Match':first_frame.headers['etag']})
        assert cached.status_code==304 and cached.content==b'' and cached.headers['X-Update-Windows']
        client.patch(url+'/battery',json=config(poll_seconds=3600),headers=auth())
        changed_policy=client.get(url+'/frame',headers=auth()|{'If-None-Match':first_frame.headers['etag']})
        assert changed_policy.status_code==304 and changed_policy.content==b'' and changed_policy.headers['X-Update-Seconds']=='3600'
    with patch.object(api,'plan',lambda row:real_plan(row,at('2026-09-13T23:00:00+02:00'))):
        quiet=client.get(url+'/frame',headers=auth())
        assert quiet.status_code==204 and quiet.content==b'' and quiet.headers['X-Poll-Seconds']==str(8*3600)
        assert client.get(url+'/image',headers=auth()).status_code==200
        assert store.get(ident)['last_seen'] is not None
    reopened=Store(tmp_path/'db.sqlite')
    assert reopened.get(ident)['schedule_timezone']=='Europe/Berlin'


def test_existing_database_migration(tmp_path):
    path=tmp_path/'old.sqlite'
    with sqlite3.connect(path) as db:
        db.execute("CREATE TABLE displays (id TEXT PRIMARY KEY,name TEXT,width INTEGER,height INTEGER,token_hash TEXT,poll_seconds INTEGER)")
        db.execute("INSERT INTO displays VALUES ('old','Desk',800,480,'hash',600)")
    row=Store(path).get('old')
    assert row['poll_seconds']==600 and row['schedule_enabled']==0 and row['update_start']==420
