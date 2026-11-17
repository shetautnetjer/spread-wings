import re

import networkx as nx

from lib.store import Store, add
from lib.store import global_add as _global_add

PAT = re.compile(r"\w+")


def build(path) -> nx.Graph:
    return nx.Graph()


def loop_regex(text):
    for m in PAT.finditer(text):
        m.render()  # want outside_object


def loop_library(g: nx.Graph):
    for node in g.nodes():
        node.render()  # want outside_object


def loop_builtin(items):
    things = list(items)
    for t in things:
        t.render()  # want imported_file


def loop_plain(items):
    for t in items:
        t.render()  # want imported_file


def returned(path):
    g = build(path)
    g.render()  # want outside_object


def passed_in(render, x):
    return render(x)  # want local_value


def alias(path):
    return _global_add(path)  # want imported_name


def local_object(seen, x):
    seen.add(x)  # want unlinked


def real_function(x):
    return add(x, 1)  # want imported_name


def typed(g: "nx.Graph"):
    g.render()  # want outside_object
