# Pins the lists of one config file to its load position with mkOrder, following the
# option schema: the module system reverses definitions at every submodule level.
lib: index:
let
  inherit (builtins)
    elem
    isAttrs
    isList
    mapAttrs
    ;

  inherit (lib) isOption mkOrder;

  orderType =
    type: value:
    if type.name == "listOf" && isList value then
      mkOrder (1000 + index) value
    else if type.name == "nullOr" then
      orderType type.nestedTypes.elemType value
    else if type.name == "submodule" && isAttrs value then
      orderOptions (type.getSubOptions [ ]) value
    else if
      elem type.name [
        "attrsOf"
        "lazyAttrsOf"
      ]
      && isAttrs value
    then
      mapAttrs (_: orderType type.nestedTypes.elemType) value
    else
      value;

  orderOptions =
    options: value:
    if isOption options then
      orderType options.type value
    else if isAttrs value then
      mapAttrs (name: v: if options ? ${name} then orderOptions options.${name} v else v) value
    else
      value;
in
orderOptions
