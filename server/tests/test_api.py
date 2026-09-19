import io

import pytest
from fastapi.testclient import TestClient
from PIL import Image, PngImagePlugin

from maclink_server.app import create_app
from maclink_server.store import Store

ADMIN = "test-admin-token-long-enough-for-tests"


@pytest.fixture
def client(tmp_path):
    return TestClient(create_app(Store(tmp_path/'db.sqlite'),ADMIN))


def auth(token=ADMIN):
    return {'Authorization':f'Bearer {token}'}


def create(client, name='Desk'):
    response = client.post('/v1/displays',json={'name':name,'width':16,'height':8},headers=auth())
    assert response.status_code == 201
    return response.json()


def png(pixel=False,metadata=''):
    image = Image.new('RGB',(16,8),'white')
    if pixel:
        image.putpixel((0,0),(0,0,0))
    output = io.BytesIO()
    info = PngImagePlugin.PngInfo()
    info.add_text('note',metadata)
    image.save(output,format='PNG',pnginfo=info)
    return output.getvalue()


def publish(client, ident, content, revision):
    return client.put(f'/v1/displays/{ident}/image',content=content,
                      headers=auth()|{'X-Revision':str(revision),'X-Observed-At':'2026-09-13T12:00:00Z'})


def test_pixel_deduplication_and_exact_single_pixel_change(client):
    ident=create(client)['display']['id']
    assert publish(client,ident,png(),1).json()['changed']
    first=client.get(f'/v1/displays/{ident}/image',headers=auth())
    result=publish(client,ident,png(metadata='different metadata'),2)
    assert result.status_code==200 and not result.json()['changed']
    same=client.get(f'/v1/displays/{ident}/image',headers=auth())
    assert same.content==first.content and same.headers['etag']==first.headers['etag']
    cached=client.get(f'/v1/displays/{ident}/image',headers=auth()|{'If-None-Match':first.headers['etag']})
    assert cached.status_code==304 and cached.content==b''
    assert publish(client,ident,png(pixel=True),3).json()['changed']
    new=client.get(f'/v1/displays/{ident}/image',headers=auth()|{'If-None-Match':first.headers['etag']})
    assert new.status_code==200 and new.headers['etag']!=first.headers['etag']


def test_authentication_and_display_isolation(client):
    a,b=create(client),create(client,'Kitchen')
    aid,bid=a['display']['id'],b['display']['id']
    publish(client,aid,png(),1)
    assert client.get('/v1/displays').status_code==401
    assert client.get('/v1/displays',headers=auth(a['device_token'])).status_code==401
    assert client.get(f'/v1/displays/{aid}/frame',headers=auth(a['device_token'])).status_code==200
    assert client.get(f'/v1/displays/{bid}/frame',headers=auth(a['device_token'])).status_code==401
    assert client.put(f'/v1/displays/{aid}/image',content=png(),headers=auth(a['device_token'])).status_code==401
    assert client.get(f'/v1/displays/{aid}/image',headers={'If-None-Match':'*'}).status_code==401
    assert client.get(f'/v1/displays/{bid}/image',headers=auth()).status_code==404


def test_stale_publications_and_acknowledgment(client):
    ident=create(client)['display']['id']
    old=publish(client,ident,png(),10).json()['display']['digest']
    latest=publish(client,ident,png(pixel=True),11).json()['display']['digest']
    assert publish(client,ident,png(),9).status_code==409
    assert publish(client,ident,png(),11).status_code==409
    assert publish(client,ident,png(pixel=True),11).status_code==200
    assert client.post(f'/v1/displays/{ident}/ack',json={'digest':old},headers=auth()).status_code==409
    assert client.post(f'/v1/displays/{ident}/ack',json={'digest':latest},headers=auth()).status_code==200
    status=client.get(f'/v1/displays/{ident}',headers=auth()).json()
    assert status['delivered_digest']==latest and status['delivered_at']


def test_frame_format_and_cache_validator(client):
    ident=create(client)['display']['id']
    publish(client,ident,png(pixel=True),1)
    frame=client.get(f'/v1/displays/{ident}/frame',headers=auth())
    assert frame.content==b'\x7f'+b'\xff'*15
    assert frame.headers['x-width']=='16' and frame.headers['x-height']=='8'
    assert client.get(f'/v1/displays/{ident}/frame',headers=auth()|{'If-None-Match':'W/'+frame.headers['etag']}).status_code==304


def test_invalid_input_does_not_replace_frame(client):
    ident=create(client)['display']['id']
    original=publish(client,ident,png(),1).json()['display']['digest']
    assert publish(client,ident,b'not an image',2).status_code==422
    assert publish(client,ident,b'x'*(4*1024*1024+1),2).status_code==413
    assert client.get(f'/v1/displays/{ident}',headers=auth()).json()['digest']==original
    assert client.post('/v1/displays',json={'name':'x','width':13},headers=auth()).status_code==422


def test_state_survives_restart(tmp_path):
    store=Store(tmp_path/'db.sqlite')
    row,token=store.create('Desk',16,8,300)
    store.publish(row['id'],png(),1,'now')
    reopened=Store(tmp_path/'db.sqlite')
    assert reopened.get(row['id'])['pixels']==b'\xff'*16
