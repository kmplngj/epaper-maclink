import hmac
import os
from pathlib import Path
from typing import Annotated

from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field, field_validator, model_validator
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from .store import Conflict, Store, public, token_hash
from .schedule import plan

MAX_IMAGE_BYTES = 4 * 1024 * 1024
bearer = HTTPBearer(auto_error=False)
Credentials = Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)]


class NewDisplay(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    width: int = Field(default=800, ge=8, le=2400, multiple_of=8)
    height: int = Field(default=480, ge=8, le=2400)
    poll_seconds: int = Field(default=300, ge=60, le=86400)


class UpdateDisplay(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    poll_seconds: int = Field(ge=60, le=86400)


class Ack(BaseModel):
    digest: str = Field(pattern=r"^[0-9a-f]{64}$")


class BatterySettings(BaseModel):
    poll_seconds: int = Field(ge=60, le=86400)
    schedule_enabled: bool
    update_start: int = Field(ge=0, le=1439)
    update_end: int = Field(ge=0, le=1439)
    schedule_timezone: str = Field(min_length=1, max_length=100)

    @field_validator('schedule_timezone')
    @classmethod
    def known_timezone(cls, value):
        try: ZoneInfo(value)
        except (ZoneInfoNotFoundError, ValueError): raise ValueError('Choose a valid time zone')
        return value

    @model_validator(mode='after')
    def distinct_hours(self):
        if self.schedule_enabled and self.update_start == self.update_end:
            raise ValueError('Choose different start and end times, or disable the daily limit')
        return self


def create_app(store: Store, admin_token: str) -> FastAPI:
    if len(admin_token) < 24:
        raise ValueError("MACLINK_ADMIN_TOKEN must be at least 24 characters")
    app = FastAPI(title="MacLink", version="0.1.0", docs_url=None, redoc_url=None)

    def admin(credentials: Credentials):
        if credentials is None or not hmac.compare_digest(credentials.credentials.encode(), admin_token.encode()):
            raise HTTPException(401, "Authentication required", headers={"WWW-Authenticate":"Bearer"})

    def authorized(display_id: str, credentials: Credentials):
        row = store.get(display_id)
        supplied = credentials.credentials if credentials else ""
        valid = hmac.compare_digest(supplied.encode(), admin_token.encode())
        valid = valid or bool(row and hmac.compare_digest(token_hash(supplied), row['token_hash']))
        if not valid:
            raise HTTPException(401, "Authentication required", headers={"WWW-Authenticate":"Bearer"})
        if row is None:
            raise HTTPException(404, "Display not found")
        return row

    @app.get('/health')
    def health() -> dict:
        return {"status":"ok", "version":"0.1.0"}

    @app.get('/v1/displays', dependencies=[Depends(admin)])
    def displays() -> list[dict]:
        return [public(row) for row in store.list()]

    @app.post('/v1/displays', dependencies=[Depends(admin)], status_code=201)
    def create_display(spec: NewDisplay) -> dict:
        row, token = store.create(spec.name,spec.width,spec.height,spec.poll_seconds)
        return {"display":public(row),"device_token":token}

    @app.patch('/v1/displays/{display_id}', dependencies=[Depends(admin)])
    def update_display(display_id: str, spec: UpdateDisplay) -> dict:
        if not store.get(display_id):
            raise HTTPException(404, "Display not found")
        return public(store.update(display_id,spec.name,spec.poll_seconds))

    @app.post('/v1/displays/{display_id}/token', dependencies=[Depends(admin)])
    def rotate_token(display_id: str) -> dict:
        if not store.get(display_id):
            raise HTTPException(404, "Display not found")
        return {"device_token":store.rotate_token(display_id)}

    @app.patch('/v1/displays/{display_id}/battery', dependencies=[Depends(admin)])
    def update_battery(display_id: str, spec: BatterySettings) -> dict:
        if not store.get(display_id):
            raise HTTPException(404, "Display not found")
        return public(store.update_battery(display_id, **spec.model_dump()))

    @app.get('/v1/displays/{display_id}')
    def status(row: Annotated[dict,Depends(authorized)]) -> dict:
        return public(row)

    @app.put('/v1/displays/{display_id}/image', dependencies=[Depends(admin)])
    async def publish(display_id: str, request: Request,
                      x_revision: Annotated[int, Header(ge=1)],
                      x_observed_at: Annotated[str, Header(max_length=100)]) -> dict:
        content = bytearray()
        async for chunk in request.stream():
            content.extend(chunk)
            if len(content) > MAX_IMAGE_BYTES:
                raise HTTPException(413,"Image too large")
        from starlette.concurrency import run_in_threadpool
        try:
            row, changed = await run_in_threadpool(store.publish,display_id,bytes(content),x_revision,x_observed_at)
        except KeyError:
            raise HTTPException(404,"Display not found")
        except Conflict as exc:
            raise HTTPException(409,str(exc))
        except ValueError as exc:
            raise HTTPException(422,str(exc))
        return {"changed":changed,"display":public(row)}

    def image_response(row, validator, raw):
        active, schedule_headers = plan(row)
        if raw and not active:
            store.record_seen(row['id'])
            return Response(status_code=204, headers=schedule_headers | {'Cache-Control':'private, no-cache'})
        if row['digest'] is None:
            raise HTTPException(404,"No image published yet",headers=schedule_headers)
        tag = '"'+row['digest']+('~raw' if raw else '~png')+'"'
        tags = [part.strip().removeprefix('W/') for part in (validator or '').split(',')]
        unchanged = tag in tags or '*' in tags
        headers = {'ETag':tag,'Cache-Control':'private, no-cache',
                   'X-Pixel-Hash':row['digest'],'X-Width':str(row['width']),
                   'X-Height':str(row['height'])} | schedule_headers
        store.record_get(row['id'],unchanged)
        return Response(status_code=304 if unchanged else 200,
                        content=None if unchanged else row['pixels' if raw else 'png'],
                        media_type='application/octet-stream' if raw else 'image/png',headers=headers)

    @app.get('/v1/displays/{display_id}/image')
    def image(row: Annotated[dict,Depends(authorized)],
              if_none_match: Annotated[str | None,Header()] = None) -> Response:
        return image_response(row,if_none_match,False)

    @app.get('/v1/displays/{display_id}/frame')
    def frame(row: Annotated[dict,Depends(authorized)],
              if_none_match: Annotated[str | None,Header()] = None) -> Response:
        return image_response(row,if_none_match,True)

    @app.post('/v1/displays/{display_id}/ack')
    def acknowledge(body: Ack,row: Annotated[dict,Depends(authorized)]) -> dict:
        try:
            store.acknowledge(row['id'],body.digest)
        except Conflict as exc:
            raise HTTPException(409,str(exc))
        return {"ok":True}

    return app


def app_factory() -> FastAPI:
    return create_app(Store(Path(os.environ.get('MACLINK_DATA_DIR','data'))/'maclink.sqlite3'),
                      os.environ.get('MACLINK_ADMIN_TOKEN',''))


# CLI imports the factory only when actually serving, keeping tests isolated.
if os.environ.get('MACLINK_ADMIN_TOKEN'):
    app = app_factory()
