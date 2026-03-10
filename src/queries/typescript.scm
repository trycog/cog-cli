(function_declaration
  name: (identifier) @name) @definition.function

(method_definition
  name: (property_identifier) @name) @definition.method

(class_declaration
  name: (type_identifier) @name) @definition.class

(export_statement
  declaration: (function_declaration
    name: (identifier) @name)) @definition.function

(function_signature
  name: (identifier) @name) @definition.function

(method_signature
  name: (property_identifier) @name) @definition.method

(abstract_method_signature
  name: (property_identifier) @name) @definition.method

(abstract_class_declaration
  name: (type_identifier) @name) @definition.class

(module
  name: (identifier) @name) @definition.module

(interface_declaration
  name: (type_identifier) @name) @definition.interface

(type_annotation
  (type_identifier) @name) @reference.type

(new_expression
  constructor: (identifier) @name) @reference.class

(call_expression
  function: [
    (identifier) @name
    (member_expression
      property: (property_identifier) @name)
  ]) @reference.call

(import_statement
  source: (string
    (string_fragment) @reference.import))

(type_alias_declaration
  name: (type_identifier) @name) @definition.type

(enum_declaration
  name: (identifier) @name) @definition.enum

(type_parameter
  name: (type_identifier) @name) @definition.type
