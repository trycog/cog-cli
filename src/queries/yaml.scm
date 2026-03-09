; Block mapping keys
(block_mapping_pair
  key: (flow_node
    (plain_scalar
      (string_scalar) @name))) @definition.property

(block_mapping_pair
  key: (flow_node
    (double_quote_scalar) @name)) @definition.property

(block_mapping_pair
  key: (flow_node
    (single_quote_scalar) @name)) @definition.property

; Flow mapping keys
(flow_pair
  key: (flow_node
    (plain_scalar
      (string_scalar) @name))) @definition.property

(flow_pair
  key: (flow_node
    (double_quote_scalar) @name)) @definition.property

(flow_pair
  key: (flow_node
    (single_quote_scalar) @name)) @definition.property
