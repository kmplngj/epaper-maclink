# /// script
# requires-python = ">=3.11"
# dependencies = ["websockets==15.0.1"]
# ///
"""Exercise the real HAKit client against an isolated, read-only protocol fixture."""
import asyncio
import json
from pathlib import Path

from websockets.asyncio.server import serve
from websockets.exceptions import ConnectionClosed


async def main():
    connections = 0
    failures = []

    async def handle(socket):
        nonlocal connections
        subscriptions = {}

        async def send(value):
            await socket.send(json.dumps(value))

        try:
            if connections:
                await asyncio.sleep(1)
            await send({"type": "auth_required", "ha_version": "2026.9.0"})
            auth = json.loads(await socket.recv())
            assert auth["type"] == "auth"
            if auth["access_token"] != "fixture-token":
                await send({"type": "auth_invalid", "message": "Invalid access token"})
                return
            connections += 1
            attempt = connections
            await send({"type": "auth_ok", "ha_version": "2026.9.0"})
            async def publish(subscription_id):
                async def event(value):
                    await send({"id": subscription_id, "type": "event", "event": value})

                if attempt == 1:
                    await event({"a": {
                        "sensor.temperature": {"s": "14.1", "a": {"friendly_name": "Outside", "unit_of_measurement": "°C"}},
                        "sensor.summary": {"s": "ready", "a": {"friendly_name": "Forecast", "content": "Rain **70%**"}},
                        "binary_sensor.washer": {"s": "on", "a": {"friendly_name": "Washer", "device_class": "running"}},
                        "light.kitchen": {"s": "on", "a": {"friendly_name": "Kitchen"}},
                    }})
                    await asyncio.sleep(0.8)
                    await event({"c": {
                        "sensor.temperature": {"+": {"s": "15.2"}},
                        "sensor.summary": {"+": {"a": {"content": "Bring **boots**"}}},
                    }})
                    await asyncio.sleep(0.8)
                    await event({"r": ["sensor.summary"]})
                    await asyncio.sleep(0.8)
                    await socket.close()
                    return
                await event({"a": {"sensor.temperature": {"s": "16.0", "a": {"friendly_name": "Outside"}}}})
                await asyncio.sleep(0.8)
                await event({"c": {"sensor.temperature": {"+": {"s": "unavailable"}}}})

            async for raw in socket:
                request = json.loads(raw)
                if request["type"] == "ping":
                    await send({"id": request["id"], "type": "pong"})
                    continue
                assert request["type"] in {"subscribe_entities", "subscribe_events", "unsubscribe_events", "supported_features"}, request["type"]
                await send({"id": request["id"], "type": "result", "success": True, "result": None})
                if request["type"] == "subscribe_entities":
                    subscriptions[request["id"]] = asyncio.create_task(publish(request["id"]))
                elif request["type"] == "unsubscribe_events":
                    if task := subscriptions.pop(request["subscription"], None):
                        task.cancel()
        except ConnectionClosed:
            pass
        except Exception as error:
            failures.append(repr(error))
        finally:
            for task in subscriptions.values():
                task.cancel()
            results = await asyncio.gather(*subscriptions.values(), return_exceptions=True)
            failures.extend(repr(error) for error in results if isinstance(error, Exception) and not isinstance(error, ConnectionClosed))

    root = Path(__file__).resolve().parent.parent
    async with serve(handle, "127.0.0.1", 0) as server:
        port = server.sockets[0].getsockname()[1]
        process = await asyncio.create_subprocess_exec(
            str(root / ".local/check-mac-integration"),
            str(root / ".local/footer-demo.png"),
            f"http://127.0.0.1:{port}",
        )
        try:
            result = await asyncio.wait_for(process.wait(), timeout=60)
        except asyncio.TimeoutError:
            process.kill()
            await process.wait()
            raise
        assert not failures, failures
        assert result == 0, f"Integration checks exited with {result}"


if __name__ == "__main__":
    asyncio.run(main())
