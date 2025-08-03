# python round-robin-router.py --ports 8000,8001,8002,8003
# python round-robin-router.py --ports 8000

from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse
from contextlib import asynccontextmanager
import httpx
import uvicorn
import argparse

TARGET_BASE_URLS = []

current_index = 0

@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.client = httpx.AsyncClient()
    yield
    await app.state.client.aclose()

app = FastAPI(lifespan=lifespan)

def create_base_urls(ports):
    global TARGET_BASE_URLS
    TARGET_BASE_URLS = [f"http://localhost:{port}" for port in ports]

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
    client: httpx.AsyncClient = request.app.state.client

    stream_generator = stream_response(request, target_url, client)

    headers, status_code = await anext(stream_generator)
    
    return StreamingResponse(
        stream_generator,
        status_code = status_code,
        headers = {key: value for key, value in headers.items() if key.lower() not in {"transfer-encoding", "content-length"}},
    )

if __name__ == "__main__":    
    parser = argparse.ArgumentParser()
    parser.add_argument("--ports", type=str, required=True)
    args = parser.parse_args()

    ports = args.ports.split(",")
    create_base_urls(ports)

    # always starts at port 30080 as per LMBench set up
    uvicorn.run(app, host="0.0.0.0", port=30080)