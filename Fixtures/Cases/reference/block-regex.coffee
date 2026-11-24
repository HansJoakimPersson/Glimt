# Inbäddad block-regex i CoffeeScript
EMAIL = ///
  ^ [\w.]+     # användare
  @ [\w.]+ $   # domän
///i
