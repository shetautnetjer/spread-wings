from app.models import Shape, total_area


def test_total_area():
    assert total_area([Shape()]) == 0.0
