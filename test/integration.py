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


def wait_for_server():
    start = time.monotonic()
    while start + 60 > time.monotonic():
        try:
            get("/num_simulations")
            return
        except:
            pass

    raise RuntimeError("Server did not start in time")


def fetch_all_static_resources():
    resource_dir = Path(__file__).parent.parent / "src/res"
    for p in resource_dir.iterdir():
        get("/" + str(p.name))


SIM_URLS = ["/reset", "/chamber.wasm", "/simulation_state"]


def fetch_sim_specific_urls(i):
    for url in SIM_URLS:
        get(f"/{i}{url}")


def fetch_sim_specific_urls_allow_failure(i):
    for url in SIM_URLS:
        try:
            get(f"/{i}{url}")
        except:
            pass


def get_lots_of_simulation_states(i):
    # Hammer the simulation state a little harder to simulate real life usage
    for _ in range(0, 60):
        get(f"/{i}/simulation_state")


def upload_module():
    wasm_module_path = Path(__file__).parent.parent / "zig-out/bin/simple.wasm"
    with open(wasm_module_path, "rb") as f:
        data = f.read()
        post_wasm_module("/upload", "asdf", data)


def main():
    wait_for_server()
    fetch_all_static_resources()

    num_sims = int(get("/num_simulations"))

    upload_module()
    upload_module()

    new_num_sims = int(get("/num_simulations"))
    if new_num_sims - num_sims != 2:
        raise RuntimeError("Upload failure")

    num_sims = new_num_sims
    for i in range(0, num_sims):
        fetch_sim_specific_urls(i)
        get_lots_of_simulation_states(i)

    fetch_sim_specific_urls_allow_failure(num_sims)

    get("/userinfo")


if __name__ == "__main__":
    main()
