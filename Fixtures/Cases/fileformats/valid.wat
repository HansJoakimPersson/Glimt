(module
  (func $identity (param $value i32) (result i32)
    local.get $value)
  (export "identity" (func $identity)))
