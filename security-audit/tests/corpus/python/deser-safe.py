import json, yaml
def load_blob(b): return json.loads(b)
def load_cfg(s):  return yaml.safe_load(s)
