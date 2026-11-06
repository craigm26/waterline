"""Check the UTM math in ios/Waterline/Geo.swift (ported line for line) against pyproj."""
from math import sin, cos, tan, sqrt, pi
from pyproj import Transformer


def utm(lon, lat, zone=10):
    a, f, k0 = 6378137.0, 1 / 298.257223563, 0.9996
    e2 = f * (2 - f); e4 = e2 * e2; e6 = e4 * e2; ep2 = e2 / (1 - e2)
    phi = lat * pi / 180; lam0 = (zone * 6 - 183) * pi / 180
    n = a / sqrt(1 - e2 * sin(phi) ** 2); t = tan(phi) ** 2; c = ep2 * cos(phi) ** 2
    A = (lon * pi / 180 - lam0) * cos(phi)
    m = a * ((1 - e2 / 4 - 3 * e4 / 64 - 5 * e6 / 256) * phi - (3 * e2 / 8 + 3 * e4 / 32 + 45 * e6 / 1024) * sin(2 * phi)
             + (15 * e4 / 256 + 45 * e6 / 1024) * sin(4 * phi) - (35 * e6 / 3072) * sin(6 * phi))
    x = k0 * n * (A + (1 - t + c) * A ** 3 / 6 + (5 - 18 * t + t * t + 72 * c - 58 * ep2) * A ** 5 / 120) + 500000
    y = k0 * (m + n * tan(phi) * (A * A / 2 + (5 - t + 9 * c + 4 * c * c) * A ** 4 / 24 + (61 - 58 * t + t * t + 600 * c - 330 * ep2) * A ** 6 / 720))
    return x, y


tr = Transformer.from_crs("EPSG:4326", "EPSG:26910", always_xy=True)
worst = 0
for lon, lat in [(-122.3935, 37.7955), (-122.5135, 37.7080), (-122.357, 37.8325), (-122.4148, 37.7633)]:
    x, y = utm(lon, lat); px, py = tr.transform(lon, lat)
    worst = max(worst, abs(x - px), abs(y - py))
    print(f"{lon},{lat}: dx {x - px:+.3f} m  dy {y - py:+.3f} m")
print("PASS" if worst < 1.5 else "FAIL", f"worst {worst:.3f} m")
