"""
End-to-end test: create game → round → POST 3 frames → fetch results.
Run with: python test_api.py
Requires the server to be running: uvicorn main:app --reload
"""

import sys
import requests

BASE = "http://localhost:8000"
TEST_IMAGES = [
    ("../cv/test_bullseye.png",    10),
    ("../cv/test_board.png",        2),
    ("../cv/test_perspective.png",  2),
]


def check(resp, expected_status=None):
    if expected_status and resp.status_code != expected_status:
        print(f"  FAIL  {resp.request.method} {resp.url}")
        print(f"        expected {expected_status}, got {resp.status_code}: {resp.text}")
        sys.exit(1)
    return resp.json()


def main():
    print("=== Backend API test ===\n")

    # Create game
    game = check(requests.post(f"{BASE}/games", json={"player_name": "TestPlayer"}), 201)
    print(f"[1] Game created  id={game['id']}  player={game['player_name']}")

    # Create round
    round_ = check(requests.post(f"{BASE}/games/{game['id']}/rounds"), 201)
    print(f"[2] Round created  id={round_['id']}  round_number={round_['round_number']}")

    # Post frames
    print(f"[3] Posting {len(TEST_IMAGES)} frames...")
    passed = 0
    for path, expected_score in TEST_IMAGES:
        with open(path, "rb") as f:
            resp = check(requests.post(
                f"{BASE}/rounds/{round_['id']}/detect",
                files={"frame": ("frame.jpg", f, "image/jpeg")},
            ))
        status = "✓" if resp["detected"] and resp["score"] == expected_score else "✗"
        print(f"    {status}  {path}")
        print(f"       detected={resp['detected']}  score={resp.get('score')}  "
              f"expected={expected_score}  x={resp.get('x')}  y={resp.get('y')}")
        if resp["detected"] and resp["score"] == expected_score:
            passed += 1

    # Fetch shots
    shots = check(requests.get(f"{BASE}/rounds/{round_['id']}/shots"))
    print(f"[4] Shots in DB: {len(shots)}")

    # End round
    ended = check(requests.patch(f"{BASE}/rounds/{round_['id']}/end"))
    print(f"[5] Round ended   ended_at={ended['ended_at']}")

    # Fetch full game
    full = check(requests.get(f"{BASE}/games/{game['id']}"))
    print(f"[6] Game detail   rounds={len(full['rounds'])}")

    print(f"\n{'PASS' if passed == len(TEST_IMAGES) else 'PARTIAL'}  {passed}/{len(TEST_IMAGES)} scores matched")


if __name__ == "__main__":
    main()
