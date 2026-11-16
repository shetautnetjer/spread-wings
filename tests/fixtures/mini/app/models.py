class Shape:
    def area(self) -> float:
        return 0.0


def total_area(shapes) -> float:
    return sum(s.area() for s in shapes)
