-- ==
-- input {
--   [1,2,3,4,5,6,7,8,9]
-- }
-- output {
--   [1, 3, 6, 10, 15, 21, 28, 36, 45]
-- }
-- compiled random input { [100000]i32 } auto output

let main(a: []i32): []i32 = scan (+) 0 a
