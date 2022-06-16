-- ==
-- input { [[1,2,3],[4,5,6],[7,8,9]] [1i64, 1i64] [1i64, -1i64] [42, 1337] }
-- output { [[1i32, 2i32, 3i32], [4i32, 47i32, 6i32], [7i32, 8i32, 9i32]] }
-- input { [[1,2,3],[4,5,6],[7,8,9]] [-1i64] [-1i64] [1337] }
-- output { [[1i32, 2i32, 3i32], [4i32, 5i32, 6i32], [7i32, 8i32, 9i32]] }
-- input { [[1,2,3],[4,5,6],[7,8,9]] [3i64] [0i64] [1337] }
-- output { [[1i32, 2i32, 3i32], [4i32, 5i32, 6i32], [7i32, 8i32, 9i32]] }
-- input { [[1,2,3],[4,5,6],[7,8,9]] [0i64] [3i64] [1337] }
-- output { [[1i32, 2i32, 3i32], [4i32, 5i32, 6i32], [7i32, 8i32, 9i32]] }
-- input { [[1,2,3],[4,5,6],[7,8,9]] [-1i64] [0i64] [1337] }
-- output { [[1i32, 2i32, 3i32], [4i32, 5i32, 6i32], [7i32, 8i32, 9i32]] }
-- input { [[1,2,3],[4,5,6],[7,8,9]] [0i64] [-1i64] [1337] }
-- output { [[1i32, 2i32, 3i32], [4i32, 5i32, 6i32], [7i32, 8i32, 9i32]] }
-- input { [[1,2,3],[4,5,6],[7,8,9]] [0i64] [0i64] [1337] }
-- output { [[1338i32, 2i32, 3i32], [4i32, 5i32, 6i32], [7i32, 8i32, 9i32]] }
-- input { [[1,2,3],[4,5,6],[7,8,9]] [3i64] [3i64] [1337] }
-- output { [[1i32, 2i32, 3i32], [4i32, 5i32, 6i32], [7i32, 8i32, 9i32]] }

def main [n][m][l] (xss: *[n][m]i32) (is: [l]i64) (js: [l]i64) (vs: [l]i32): [n][m]i32 =
  reduce_by_index_2d xss (+) 0 (zip is js) vs