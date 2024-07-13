import urllib
import urllib.request
import time
from pathlib import Path
import uuid
import json

SERVER = "http://localhost:8000"
# '1' ** 32 base64url encoded by zig std
cookie = "session_id=MTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTE="
admin_cookie = "session_id=MjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjI="


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


def get(url, is_admin=False):
    url = SERVER + url
    req_cookie = cookie
    if is_admin:
        req_cookie = admin_cookie

    req = urllib.request.Request(url, headers={"Cookie": req_cookie})
    response = urllib.request.urlopen(req)
    return response.read()


def put(url, data, is_admin=False):
    url = SERVER + url

    req_cookie = cookie
    if is_admin:
        req_cookie = admin_cookie

    req = urllib.request.Request(
        url, method="PUT", data=data, headers={"Cookie": req_cookie}
    )
    response = urllib.request.urlopen(req)
    return response.read()


def wait_for_server():
    start = time.monotonic()
    while start + 60 > time.monotonic():
        try:
            get("/init_info")
            return
        except:
            pass

    raise RuntimeError("Server did not start in time")


def fetch_all_static_resources():
    resource_dir = Path(__file__).parent.parent / "src/res"
    for p in resource_dir.iterdir():
        get("/" + str(p.name))


def fetch_chambers(chamber_ids):
    for chamber_id in chamber_ids:
        get(f"/{chamber_id}/chamber.wasm")


def get_lots_of_simulation_states():
    # Hammer the simulation state a little harder to simulate real life usage
    last_state = 0
    simulation_states = json.loads(get(f"/simulation_state"))
    if len(simulation_states) > 0:
        last_state = simulation_states[-1]["num_steps_taken"]

    for _ in range(0, 60):
        simulation_states = json.loads(get(f"/simulation_state?since={last_state}"))
        if len(simulation_states) > 0:
            last_state = simulation_states[-1]["num_steps_taken"]


def upload_module(name):
    wasm_module_path = Path(__file__).parent.parent / "zig-out/bin" / name
    with open(wasm_module_path, "rb") as f:
        data = f.read()
        post_wasm_module("/upload", "asdf", data)


def test_num_balls():
    initial_num_balls = get_init_info()["num_balls"]

    test_num_balls = initial_num_balls + 10
    test_num_balls_data = str(test_num_balls).encode()
    try:
        put("/num_balls", test_num_balls_data, False)
    except Exception:
        pass

    put("/num_balls", test_num_balls_data, True)

    new_num_balls = get_init_info()["num_balls"]
    if new_num_balls != test_num_balls:
        raise RuntimeError("Failed to set number of balls")


def test_chambers_per_row():
    initial_chambers_per_row = get_init_info()["chambers_per_row"]

    test_chambers_per_row = initial_chambers_per_row + 2
    test_chambers_per_row_data = str(test_chambers_per_row).encode()

    try:
        put("/chambers_per_row", test_chambers_per_row_data, False)
        raise RuntimeError("Setting chambers per row as user should fail")
    except Exception:
        pass

    put("/chambers_per_row", test_chambers_per_row_data, True)

    new_chambers_per_row = get_init_info()["chambers_per_row"]
    if new_chambers_per_row != test_chambers_per_row:
        raise RuntimeError("Failed to set number of balls")


def test_reset():
    try:
        get("/reset")
        raise RuntimeError("/reset should only work as admin")
    except Exception:
        pass

    get("/reset")


def get_init_info():
    return json.loads(get("/init_info"))


def get_num_chambers(init_info):
    return len(init_info["chamber_ids"])


def ensure_num_chambers(num_chambers, purpose):
    init_info = get_init_info()
    new_num_chambers = get_num_chambers(init_info)
    if new_num_chambers != num_chambers:
        raise RuntimeError(purpose)


def chambers_pending_validation():
    chambers = json.loads(get("/chambers?state=pending_validation"))
    return len(chambers) != 0


def get_unaccepted_chamber_ids():
    unaccepted_chambers = json.loads(get("/chambers?state=validated"))
    return map(lambda x: x["chamber_id"], iter(unaccepted_chambers))


def make_reject_url(chamber_id):
    return "/reject_chamber?id={}".format(chamber_id)


def make_accept_url(chamber_id):
    return "/accept_chamber?id={}".format(chamber_id)


def test_unauntheticated_accept_reject(chamber_id):
    try:
        get(make_reject_url(chamber_id))
        raise RuntimeError("Rejection should fail if non-admin")
    except Exception:
        pass

    try:
        get(make_accept_url(chamber_id))
        raise RuntimeError("Accept should fail if non-admin")
    except Exception:
        pass


def main():
    wait_for_server()
    fetch_all_static_resources()

    init_info = get_init_info()
    num_chambers = get_num_chambers(init_info)

    upload_module("spinny_bar.wasm")
    upload_module("counter.wasm")

    while chambers_pending_validation():
        time.sleep(1)

    ensure_num_chambers(num_chambers, "Chambers should not be accepted")

    chamber_it = get_unaccepted_chamber_ids()
    first_chamber_id = next(chamber_it)
    test_unauntheticated_accept_reject(first_chamber_id)

    get(make_reject_url(first_chamber_id), True)
    get(make_accept_url(next(chamber_it)), True)

    ensure_num_chambers(num_chambers + 1, "Accepted chamber not present")

    init_info = get_init_info()
    fetch_chambers(init_info["chamber_ids"])

    get_lots_of_simulation_states()
    test_num_balls()
    test_chambers_per_row()

    get("/userinfo")
    get("/")
    get("/my_chambers")


if __name__ == "__main__":
    main()
