"""Measure download throughput from candidate torch wheel sources (China-friendly first)."""
import re
import time
import urllib.parse
import urllib.request

UA = {"User-Agent": "Mozilla/5.0"}


def speed(url, nbytes=15_000_000, timeout=30):
    try:
        req = urllib.request.Request(url, headers=dict(UA, Range="bytes=0-%d" % nbytes))
        t0 = time.time()
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = r.read(nbytes)
        dt = max(time.time() - t0, 0.001)
        return "%.2f MB/s (%d bytes in %.1fs)" % (len(data) / 1e6 / dt, len(data), dt)
    except Exception as e:
        return "FAIL %s %s" % (type(e).__name__, str(e)[:100])


print("1) download.pytorch.org cu124 wheel")
print("   ", speed("https://download.pytorch.org/whl/cu124/torch-2.5.1%2Bcu124-cp312-cp312-win_amd64.whl"))

print("2) tsinghua PyPI index for torch")
try:
    with urllib.request.urlopen("https://pypi.tuna.tsinghua.edu.cn/simple/torch/", timeout=30) as r:
        html = r.read().decode("utf-8", "replace")
    wheels = re.findall(r'href="([^"]*cp312-cp312-win_amd64\.whl[^"]*)"', html)
    print("    cp312 win wheels:", len(wheels))
    if wheels:
        url = urllib.parse.urljoin("https://pypi.tuna.tsinghua.edu.cn/simple/torch/", wheels[-1])
        print("    newest:", url[:120])
        print("   ", speed(url))
except Exception as e:
    print("    FAIL", type(e).__name__, str(e)[:120])

print("3) aliyun PyPI index for torch")
try:
    with urllib.request.urlopen("https://mirrors.aliyun.com/pypi/simple/torch/", timeout=30) as r:
        html = r.read().decode("utf-8", "replace")
    wheels = re.findall(r'href="([^"]*cp312-cp312-win_amd64\.whl[^"]*)"', html)
    print("    cp312 win wheels:", len(wheels))
    if wheels:
        url = urllib.parse.urljoin("https://mirrors.aliyun.com/pypi/simple/torch/", wheels[-1])
        print("   ", speed(url))
except Exception as e:
    print("    FAIL", type(e).__name__, str(e)[:120])
