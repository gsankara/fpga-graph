#!/bin/bash
# docker_check.sh -- can we run the Docker/Ubuntu-22.04 build path here?
echo "=== docker usable by this user? ==="
if docker info >/dev/null 2>&1; then echo "docker OK"; else echo "docker NOT usable: $(docker info 2>&1 | head -1)"; fi
id | tr ' ' '\n' | grep -i docker || echo "(not in docker group -- may be rootless/socket-permitted anyway)"
echo
echo "=== locally cached images ==="
docker images 2>/dev/null | head -25
echo
echo "=== real internet test (curl on this box is broken; use python) ==="
python3 - <<'PY'
import urllib.request
for url in ("https://registry-1.docker.io/v2/", "https://www.google.com"):
    try:
        urllib.request.urlopen(url, timeout=8); print("REACHABLE:", url)
    except Exception as e:
        print("UNREACHABLE:", url, "->", type(e).__name__, str(e)[:80])
PY
echo
echo "=== can docker pull? (small image dry-run) ==="
timeout 25 docker pull hello-world 2>&1 | tail -3
echo
echo "=== tools/license present to mount into a container ==="
ls -d /tools/Xilinx/Vitis/2023.2 /opt/xilinx/xrt ~/u280dev 2>/dev/null
echo "license: ${XILINXD_LICENSE_FILE:-unset}"
