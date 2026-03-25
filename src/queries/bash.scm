; Function definitions (both `function foo() {}` and `foo() {}` syntax)
(function_definition
  name: (word) @name) @definition.function

; Top-level variable assignments (VAR=value)
(variable_assignment
  name: (variable_name) @name) @definition.variable

; Variables declared with export/local/declare/typeset/readonly
(declaration_command
  (variable_assignment
    name: (variable_name) @name)) @definition.variable

; Command calls
(command
  name: (command_name) @name) @reference.call
