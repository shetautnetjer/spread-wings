from app.models import Shape, total_area
from . import util


def run():
    shapes = [Shape(), Shape()]
    print(total_area(shapes))
    util.helper()
