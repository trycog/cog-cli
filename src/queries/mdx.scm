; Markdown headings
(atx_heading
  heading_content: (markdown_inline) @name) @definition.module

; Exported classes
(export_statement
  declaration: (class_declaration
    name: (_) @name)) @definition.class

; Function declarations
[
  (function_expression
    name: (identifier) @name)
  (function_declaration
    name: (identifier) @name)
  (generator_function
    name: (identifier) @name)
  (generator_function_declaration
    name: (identifier) @name)
] @definition.function

; Exported function declarations
(export_statement
  declaration: (function_declaration
    name: (identifier) @name)) @definition.function

(export_statement
  declaration: (generator_function_declaration
    name: (identifier) @name)) @definition.function

; Variable-assigned functions
(lexical_declaration
  (variable_declarator
    name: (identifier) @name
    value: [(arrow_function) (function_expression)]) @definition.function)

(variable_declaration
  (variable_declarator
    name: (identifier) @name
    value: [(arrow_function) (function_expression)]) @definition.function)

; JSX component references
(jsx_opening_element
  name: (identifier) @name) @reference.class

(jsx_self_closing_element
  name: (identifier) @name) @reference.class
