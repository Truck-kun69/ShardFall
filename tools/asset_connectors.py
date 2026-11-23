#!/usr/bin/env python3
"""Provider-agnostic, queued asset-generation pipeline (connector layer).

The game ships on procedural/CC0 fallbacks at $0.00. This tool is the ready-to-
fire path for when credits are invested. It NEVER spends money unless ALL of:
  1. --run-connectors is passed,
  2. the provider API key is present in the environment (FAL_KEY for fal.ai),
  3. --cap USD is > 0 and the estimated cost of the queued work fits under it.

Stages per slot (see godot/models/README.md for the slot contract):
  concept   fal-ai/flux/schnell            shared dark-fantasy earth-tone PBR prompt prefix
  mesh      heroes/bosses: fal-ai/meshy/v7.1/image-to-3d
            foes/props:    fal-ai/hunyuan-3d/v3.1/pro/image-to-3d (rapid for clutter)
  rig       heroes/bosses: fal-ai/meshy/rigging/multi-animation
  audio     fal-ai/elevenlabs/sound-effects/v2   (optional, --with-audio)

Outputs land in tools/asset_raw/<category>/ and are then normalised by
tools/blender/process_assets.py into godot/models/. Every request is cached in
tools/asset_cache.json (keyed by stage+model+inputs) so reruns resume instead of
paying twice.

Examples:
  python3 tools/asset_connectors.py --plan                 # dry run, full queue
  python3 tools/asset_connectors.py --plan --canary        # 1 hero + 1 prop
  FAL_KEY=... python3 tools/asset_connectors.py --run-connectors --canary --cap 5
"""
import argparse
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE_PATH = os.path.join(ROOT, "tools", "asset_cache.json")
RAW_DIR = os.path.join(ROOT, "tools", "asset_raw")

STYLE_PREFIX = ("dark fantasy, grounded earth-tone palette, weathered hand-painted PBR game asset, "
                "readable silhouette, neutral overcast studio lighting, plain light-grey background, "
                "single subject, full body, three-quarter view, no text, no watermark, ")

# Estimated USD per call. ESTIMATES ONLY: confirm current provider pricing before a
# real run and edit here; the hard cap is enforced against these numbers and
# against any cost the provider reports back.
PRICE_USD = {
    "fal-ai/flux/schnell": 0.003,
    "fal-ai/meshy/v7.1/image-to-3d": 0.80,
    "fal-ai/meshy/rigging/multi-animation": 0.40,
    "fal-ai/hunyuan-3d/v3.1/pro/image-to-3d": 0.45,
    "fal-ai/hunyuan-3d/v3.1/rapid/image-to-3d": 0.20,
    "fal-ai/elevenlabs/sound-effects/v2": 0.02,
}

HERO_CLIPS = ["idle", "walk", "run", "cast", "roll", "jump", "die"]
BOSS_CLIPS = ["idle", "walk", "attack", "slam", "die"]

# Slot table: (category, id, description, mesh model, rig?)
SLOTS = [
    ("heroes", "warden", "armoured shield-knight with a short sword and kite shield, bronze and leather", "meshy", True),
    ("heroes", "spark", "lightning mage in a hooded blue robe holding a crackling staff", "meshy", True),
    ("heroes", "ember", "fire witch in dark red layered robes with a glowing ember in her hand", "meshy", True),
    ("heroes", "storm", "frost tide-caller in teal scale armour carrying an ice-tipped spear", "meshy", True),
    ("bosses", "gravelord", "towering grave-giant of stone and bone, hunched, huge fists", "meshy", True),
    ("bosses", "pyre_colossus", "molten iron colossus with cracked glowing seams", "meshy", True),
    ("bosses", "rimeheart", "ice-crusted horned brute with a frozen heart in its chest", "meshy", True),
    ("bosses", "tidewarden", "barnacled sea titan with a lantern-lit maw", "meshy", True),
    ("bosses", "shard_sovereign", "crystal-crowned rift king, violet shards growing from its back", "meshy", True),
    ("foes", "grunt", "hunched ghoul footsoldier with ragged cloth", "hunyuan_pro", False),
    ("foes", "runner", "lean four-legged rift hound", "hunyuan_pro", False),
    ("foes", "brute", "massive ogre bruiser with oversized arms", "hunyuan_pro", False),
    ("foes", "spitter", "bloated sac-backed creature with a long neck", "hunyuan_pro", False),
    ("foes", "charger", "horned armoured boar beast", "hunyuan_pro", False),
    ("props", "tree", "gnarled pine tree", "hunyuan_pro", False),
    ("props", "tree_dead", "dead leafless tree with twisted branches", "hunyuan_pro", False),
    ("props", "arch", "ruined stone archway, open centre", "hunyuan_pro", False),
    ("props", "pillar", "broken carved stone pillar", "hunyuan_pro", False),
    ("props", "wall", "crumbling low stone wall segment", "hunyuan_pro", False),
    ("props", "rock", "mossy boulder", "hunyuan_rapid", False),
    ("props", "bush", "dense low shrub", "hunyuan_rapid", False),
    ("props", "bones", "pile of old ribcage bones and a skull", "hunyuan_rapid", False),
]
AUDIO = [("hit", "short meaty impact"), ("roll", "cloth whoosh dodge roll"), ("jump", "light leap grunt and cloth flutter"),
         ("levelup", "bright magical chime rising"), ("boss", "deep monstrous roar"), ("perfect", "crisp time-slow shimmer")]

MESH_MODEL = {
    "meshy": "fal-ai/meshy/v7.1/image-to-3d",
    "hunyuan_pro": "fal-ai/hunyuan-3d/v3.1/pro/image-to-3d",
    "hunyuan_rapid": "fal-ai/hunyuan-3d/v3.1/rapid/image-to-3d",
}


# ----------------------------------------------------------------------------
# Backends
# ----------------------------------------------------------------------------
class Backend:
    """Pluggable provider adapter."""
    name = "base"
    key_env = ""

    def available(self):
        return bool(self.key_env and os.environ.get(self.key_env))

    def submit(self, model, payload):
        raise NotImplementedError

    def wait(self, handle, timeout_s):
        raise NotImplementedError


class FalBackend(Backend):
    """fal.ai queue API: POST queue.fal.run/<model>, poll status_url, GET response_url."""
    name = "fal"
    key_env = "FAL_KEY"
    base = "https://queue.fal.run/"

    def _req(self, url, body=None):
        headers = {"Authorization": "Key " + os.environ[self.key_env], "Content-Type": "application/json",
                   "User-Agent": "asset-connectors/1.0"}
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, headers=headers, method="POST" if body is not None else "GET")
        with urllib.request.urlopen(req, timeout=120) as resp:
            return json.loads(resp.read().decode())

    def submit(self, model, payload):
        r = self._req(self.base + model, payload)
        return {"request_id": r["request_id"], "status_url": r["status_url"], "response_url": r["response_url"]}

    def wait(self, handle, timeout_s):
        t0 = time.time()
        while time.time() - t0 < timeout_s:
            st = self._req(handle["status_url"])
            if st.get("status") == "COMPLETED":
                return self._req(handle["response_url"])
            if st.get("status") in ("FAILED", "ERROR", "CANCELLED"):
                raise RuntimeError(f"request {handle['request_id']} {st.get('status')}: {st}")
            time.sleep(4.0)
        raise TimeoutError(f"request {handle['request_id']} timed out after {timeout_s}s")


class TripoBackend(Backend):
    """Future adapter slot (Tripo / Rodin). Selecting it fails loudly until implemented."""
    name = "tripo"
    key_env = "TRIPO_KEY"

    def submit(self, model, payload):
        raise NotImplementedError("Tripo/Rodin adapter not implemented yet; use --backend fal")


BACKENDS = {"fal": FalBackend, "tripo": TripoBackend}


# ----------------------------------------------------------------------------
# Queue construction
# ----------------------------------------------------------------------------
def build_queue(canary=False, only=None, with_audio=False):
    jobs = []
    slots = SLOTS
    if canary:
        slots = [s for s in SLOTS if (s[0], s[1]) in (("heroes", "warden"), ("props", "rock"))]
    if only:
        slots = [s for s in slots if s[0] in only]
    for cat, ident, desc, mesh, rig in slots:
        prompt = STYLE_PREFIX + desc + (", T-pose, arms out" if rig else ", centred, whole object visible")
        jobs.append({"stage": "concept", "cat": cat, "id": ident, "model": "fal-ai/flux/schnell",
                     "payload": {"prompt": prompt, "image_size": "square_hd", "num_inference_steps": 4,
                                 "num_images": 1, "seed": int(hashlib.sha1(ident.encode()).hexdigest()[:6], 16)}})
        mesh_payload = {"image_url": "{concept}", "enable_pbr": True}
        if mesh == "meshy":
            mesh_payload.update({"topology": "triangle", "target_polycount": 30000, "should_texture": True})
        else:
            mesh_payload = {"input_image_url": "{concept}", "enable_pbr": True,
                            "face_count": 16000 if cat == "foes" else 20000}
        jobs.append({"stage": "mesh", "cat": cat, "id": ident, "model": MESH_MODEL[mesh], "payload": mesh_payload})
        if rig:
            clips = HERO_CLIPS if cat == "heroes" else BOSS_CLIPS
            jobs.append({"stage": "rig", "cat": cat, "id": ident, "model": "fal-ai/meshy/rigging/multi-animation",
                         "payload": {"model_url": "{mesh}", "height_meters": 1.8 if cat == "heroes" else 4.2,
                                     "animations": clips}})
    if with_audio and not canary:
        for ident, desc in AUDIO:
            jobs.append({"stage": "audio", "cat": "audio", "id": ident, "model": "fal-ai/elevenlabs/sound-effects/v2",
                         "payload": {"text": desc, "duration_seconds": 1.5}})
    for j in jobs:
        j["cost"] = PRICE_USD[j["model"]]
        j["key"] = hashlib.sha256(json.dumps([j["stage"], j["model"], j["cat"], j["id"], j["payload"]],
                                             sort_keys=True).encode()).hexdigest()[:20]
    return jobs


def load_cache():
    if os.path.exists(CACHE_PATH):
        with open(CACHE_PATH, encoding="utf-8") as fh:
            return json.load(fh)
    return {"version": 1, "spent_usd": 0.0, "jobs": {}}


def save_cache(cache):
    tmp = CACHE_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(cache, fh, indent=2, sort_keys=True)
    os.replace(tmp, CACHE_PATH)


def find_urls(obj, exts):
    out = []
    if isinstance(obj, dict):
        for v in obj.values():
            out += find_urls(v, exts)
    elif isinstance(obj, list):
        for v in obj:
            out += find_urls(v, exts)
    elif isinstance(obj, str) and obj.startswith("http") and obj.split("?")[0].lower().endswith(exts):
        out.append(obj)
    return out


def download(url, dest):
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with urllib.request.urlopen(url, timeout=300) as resp, open(dest, "wb") as fh:
        fh.write(resp.read())


# ----------------------------------------------------------------------------
def plan(jobs, cache, cap):
    pending = [j for j in jobs if cache["jobs"].get(j["key"], {}).get("status") != "done"]
    total = sum(j["cost"] for j in pending)
    print(f"{'stage':8} {'slot':26} {'model':44} {'est $':>7}  state")
    for j in jobs:
        st = cache["jobs"].get(j["key"], {}).get("status", "queued")
        print(f"{j['stage']:8} {j['cat'] + '/' + j['id']:26} {j['model']:44} {j['cost']:7.3f}  {st}")
    print(f"jobs: {len(jobs)} total, {len(pending)} pending | estimated pending cost ${total:.2f} | "
          f"spent so far ${cache.get('spent_usd', 0.0):.2f} | cap ${cap:.2f}")
    return total


def run(jobs, cache, cap, backend):
    spent = float(cache.get("spent_usd", 0.0))
    results = {}
    for j in jobs:
        entry = cache["jobs"].get(j["key"], {})
        if entry.get("status") == "done":
            results[(j["cat"], j["id"], j["stage"])] = entry["outputs"]
            continue
        if spent + j["cost"] > cap + 1e-9:
            print(f"CAP REACHED: next job {j['stage']} {j['cat']}/{j['id']} (${j['cost']:.2f}) would exceed ${cap:.2f}; stopping.")
            break
        payload = json.loads(json.dumps(j["payload"]))
        for k, v in payload.items():
            if v == "{concept}":
                payload[k] = (results.get((j["cat"], j["id"], "concept")) or [None])[0]
            elif v == "{mesh}":
                payload[k] = (results.get((j["cat"], j["id"], "mesh")) or [None])[0]
        if None in payload.values():
            print(f"SKIP (missing upstream output): {j['stage']} {j['cat']}/{j['id']}")
            continue
        print(f"-> {j['stage']} {j['cat']}/{j['id']} via {j['model']}")
        handle = entry.get("handle") or backend.submit(j["model"], payload)
        cache["jobs"][j["key"]] = {"status": "submitted", "handle": handle, "model": j["model"]}
        save_cache(cache)
        out = backend.wait(handle, 1800)
        exts = {"concept": (".png", ".jpg", ".jpeg", ".webp"), "mesh": (".glb",), "rig": (".glb",),
                "audio": (".mp3", ".wav", ".ogg")}[j["stage"]]
        urls = find_urls(out, exts)
        if not urls:
            raise RuntimeError(f"{j['model']} returned no {exts} output: {json.dumps(out)[:400]}")
        ext = os.path.splitext(urls[0].split("?")[0])[1]
        dest = os.path.join(RAW_DIR, j["cat"], f"{j['id']}_{j['stage']}{ext}")
        download(urls[0], dest)
        cost = float(out.get("cost", j["cost"])) if isinstance(out, dict) else j["cost"]
        spent += cost
        cache["spent_usd"] = spent
        cache["jobs"][j["key"]] = {"status": "done", "handle": handle, "model": j["model"], "outputs": urls,
                                   "file": os.path.relpath(dest, ROOT), "cost_usd": cost, "ts": time.time()}
        save_cache(cache)
        results[(j["cat"], j["id"], j["stage"])] = urls
    print(f"spent ${spent:.2f} of ${cap:.2f} cap. Next: blender -b -P tools/blender/process_assets.py -- --raw tools/asset_raw --out godot/models")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--plan", action="store_true", help="dry run: print queue and cost estimate (default)")
    ap.add_argument("--run-connectors", action="store_true", help="actually call providers (spends money)")
    ap.add_argument("--canary", action="store_true", help="only 1 hero (warden) + 1 prop (rock)")
    ap.add_argument("--cap", type=float, default=0.0, help="hard USD spend cap (default 0.00)")
    ap.add_argument("--only", default="", help="comma list of categories: heroes,bosses,foes,props")
    ap.add_argument("--with-audio", action="store_true", help="also queue ElevenLabs SFX")
    ap.add_argument("--backend", default="fal", choices=sorted(BACKENDS))
    args = ap.parse_args()
    jobs = build_queue(args.canary, set(filter(None, args.only.split(","))), args.with_audio)
    cache = load_cache()
    est = plan(jobs, cache, args.cap)
    if not args.run_connectors:
        print("DRY RUN: no provider calls made, $0.00 spent. Pass --run-connectors with an API key and --cap to execute.")
        return 0
    backend = BACKENDS[args.backend]()
    if not backend.available():
        print(f"REFUSED: --run-connectors requires {backend.key_env} in the environment. Nothing was spent.")
        return 2
    if args.cap <= 0.0:
        print("REFUSED: --cap must be > 0 to spend. Nothing was spent.")
        return 2
    if est > args.cap and not args.canary:
        print(f"NOTE: estimated ${est:.2f} exceeds cap ${args.cap:.2f}; the run will stop at the cap.")
    try:
        run(jobs, cache, args.cap, backend)
    except (urllib.error.URLError, RuntimeError, TimeoutError, NotImplementedError) as exc:
        print(f"CONNECTOR ERROR: {exc}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
