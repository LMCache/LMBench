from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse
from contextlib import asynccontextmanager
import httpx

TARGET_BASE_URLS = [
    "http://localhost:8001"
]

current_index = 0

@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.client = httpx.AsyncClient()
    yield
    await app.state.client.aclose()

app = FastAPI(lifespan=lifespan)

async def stream_response(request, backend_url, client):
    async with client.stream(
        method = request.method,
        url = backend_url,
        headers = dict(request.headers),
        content = await request.body(),
    ) as backend_response:

        yield backend_response.headers, backend_response.status_code

        async for chunk in backend_response.aiter_bytes():
            yield chunk


@app.api_route("/{full_path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
async def proxy(full_path: str, request: Request):
    global current_index

    target_base = TARGET_BASE_URLS[current_index]
    current_index = (current_index + 1) % len(TARGET_BASE_URLS)
    target_url = f"{target_base}/{full_path}"

    method = request.method
    headers = dict(request.headers)
    headers.pop("host", None)
    body = await request.body()
    client: httpx.AsyncClient = request.app.state.client

    stream_generator = stream_response(request, target_url, client)

    headeres, status_code = await anext(stream_generator)
    
    return StreamingResponse(
        stream_generator,
        status_code = status_code,
        headers = {key: value for key, value in headers.items() if key.lower() not in {"transfer-encoding", "content-length"}},
    )