import pickle, yaml
def load_blob(b): return pickle.loads(b)
def load_cfg(s):  return yaml.load(s)
