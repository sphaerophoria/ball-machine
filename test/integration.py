import urllib
import urllib.request
import time
from pathlib import Path
import uuid

SERVER = "http://localhost:8000"
# '1' ** 32 base64url encoded by zig std
cookie = "session_id=MTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTE="


def post_wasm_module(url, name, module_data):
    url = f"{SERVER}{url}"
    boundary = uuid.uuid4()
    body = "\r\n".join(
        [
            f"--{boundary}",
            'Content-Disposition: form-data; name="name"',
            "",
            name,
            f"--{boundary}",
            'Content-Disposition: form-data; name="chamber"',
            "",
            "",
        ]
    ).encode()
    body += module_data

    content_type = f"multipart/form-data; boundary={boundary}"

    request = urllib.request.Request(url, data=body)
    request.add_header("Cookie", cookie)
    request.add_header("Content-Type", content_type)
    request.add_header("Content-Length", str(len(body)))

    with urllib.request.urlopen(request) as response:
        return response.read()


def get(url):
    url = SERVER + url
    req = urllib.request.Request(url, headers={"Cookie": cookie})
    response = urllib.request.urlopen(req)
    return response.read()


def put(url, data):
    url = SERVER + url
    req = urllib.request.Request(
        url, method="PUT", data=data, headers={"Cookie": cookie}
    )
    response = urllib.request.urlopen(req)
    return response.read()


def wait_for_server():
    start = time.monotonic()
    while start + 60 > time.monotonic():
        try:
            get("/num_chambers")
            return
        except:
            pass

    raise RuntimeError("Server did not start in time")


def fetch_all_static_resources():
    resource_dir = Path(__file__).parent.parent / "src/res"
    for p in resource_dir.iterdir():
        get("/" + str(p.name))


SIM_URLS = ["/chamber.wasm"]


def fetch_sim_specific_urls(i):
    for url in SIM_URLS:
        get(f"/{i}{url}")


def fetch_sim_specific_urls_allow_failure(i):
    for url in SIM_URLS:
        try:
            get(f"/{i}{url}")
        except:
            pass


def get_lots_of_simulation_states():
    # Hammer the simulation state a little harder to simulate real life usage
    for _ in range(0, 60):
        get(f"/simulation_state")


def upload_module(name):
    wasm_module_path = Path(__file__).parent.parent / "zig-out/bin" / name
    with open(wasm_module_path, "rb") as f:
        data = f.read()
        post_wasm_module("/upload", "asdf", data)


def test_num_balls():
    initial_num_balls = int(get("/num_balls"))

    test_num_balls = initial_num_balls + 10
    test_num_balls_data = str(test_num_balls).encode()
    put("/num_balls", test_num_balls_data)

    new_num_balls = int(get("/num_balls"))
    if new_num_balls != test_num_balls:
        raise RuntimeError("Failed to set number of balls")


def test_chambers_per_row():
    initial_chambers_per_row = int(get("/chambers_per_row"))

    test_chambers_per_row = initial_chambers_per_row + 2
    test_chambers_per_row_data = str(test_chambers_per_row).encode()
    put("/chambers_per_row", test_chambers_per_row_data)

    new_chambers_per_row = int(get("/chambers_per_row"))
    if new_chambers_per_row != test_chambers_per_row:
        raise RuntimeError("Failed to set number of balls")


def main():
    wait_for_server()
    fetch_all_static_resources()

    num_chambers = int(get("/num_chambers"))

    upload_module("simple.wasm")
    upload_module("platforms.wasm")
    upload_module("plinko.wasm")
    upload_module("plinko.wasm")

    new_num_chambers = int(get("/num_chambers"))
    if new_num_chambers - num_chambers != 4:
        raise RuntimeError("Upload failure")

    num_chambers = new_num_chambers
    for i in range(0, num_chambers):
        fetch_sim_specific_urls(i)

    fetch_sim_specific_urls_allow_failure(num_chambers)

    get_lots_of_simulation_states()
    test_num_balls()
    test_chambers_per_row()

    get("/reset")
    get("/userinfo")
    get("/")
    get("/num_chambers")
    get("/chamber_height")


if __name__ == "__main__":
    main()
