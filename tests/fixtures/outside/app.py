import networkx as nx
from networkx import Graph
import importlib as il

G = nx.Graph()
H = nx.Graph()


def ok():
    g = nx.Graph()
    g.render()  # want outside_object


def plain(other):
    g = nx.Graph()
    g = other
    g.render()  # want by_name


def tup():
    g = nx.Graph()
    g, r = make_two()
    g.render()  # want by_name


def loop(things):
    g = nx.Graph()
    for g in things:
        g.render()  # want by_name


def withas(e):
    g = nx.Graph()
    with e as g:
        g.render()  # want by_name


def param(G):
    G.render()  # want by_name


def modlevel():
    G.render()  # want outside_object


def typed(g: GraphView):
    g.render()  # want by_name


def typed_ok(g: nx.Graph):
    g.render()  # want outside_object


def typed_ok2(a, g: Graph):
    g.render()  # want outside_object


def setter(x):
    global H
    H = x


def user():
    H.render()  # want by_name


def dyn():
    mod = il.import_module("lib.a")
    mod.render()  # want by_name
