# invalid selector in global scope

```pactum
pact 1
pact 2

import "some/package"
import "pact/http"

pact meshapi.gateway.

pact meshapi.gateway..

message Something {
  name: string #required,
}
```

```yaml
imports:
  - alias: ""
    implicit: false
    path: "some/package"
  - alias: ""
    implicit: false
    path: "pact/http"
messages:
  - name: "Something"
    fields:
      - name: "name"
        type: "string"
        nullable: false
        options:
          - raw: false
            private: false
            selector: "required"
            value: true

1:6[5] expected selector segment @literal=1
2:6[12] expected selector segment @literal=2
9:1[80] expected selector segment @literal=pact
9:22[101-102] unexpected token @literal=.
```

# unterminated string literals

```pactum
pact meshapi.gateway

import "something

interface some_service {}
```

```yaml
pact: "meshapi.gateway"
imports:
  - alias: ""
    implicit: false
    path: "something"
interfaces:
  - name: "some_service"

3:8[29] unterminated string @literal="something
```

# bad import

```pactum
pact meshapi.gateway

import

interface some_service {}

message User {}
```

```yaml
pact: "meshapi.gateway"
messages:
  - name: "User"
interfaces:
  - name: "some_service"

5:1[30] expected path string @literal=interface
```

# unterminated import path inside import group

```pactum
pact meshapi.gateway

import (
	_ "some/unterminated/string
	some_package "some/nice/package"
)

interface some_service {}

message User {}
```

```yaml
pact: "meshapi.gateway"
imports:
  - alias: ""
    implicit: true
    path: "some/unterminated/string"
  - alias: "some_package"
    implicit: false
    path: "some/nice/package"
messages:
  - name: "User"
interfaces:
  - name: "some_service"

4:4[34] unterminated string @literal="some/unterminated/string
```

# incomplete import inside group

```pactum
pact meshapi.gateway

import (
	_
	some_package "some/nice/package"
	another_package "some/ok/package"
)

interface some_service {}

message User {}
```

```yaml
pact: "meshapi.gateway"
imports:
  - alias: "some_package"
    implicit: false
    path: "some/nice/package"
  - alias: "another_package"
    implicit: false
    path: "some/ok/package"
messages:
  - name: "User"
interfaces:
  - name: "some_service"

5:2[35] expected path string @literal=some_package
```

# import group eof

```pactum
import (
 _ "some/package"
```

```yaml
imports:
  - alias: ""
    implicit: true
    path: "some/package"

0:0[0] unexpected end of file @literal=
```

# bad const simple values

```pactum
pact meshapi.gateway

const (
	b = pancake
	x = 2.3 5
	c = false
)

const name = pancake
interface some_service {}

message User {}
```

```yaml
pact: "meshapi.gateway"
constants:
  - name: "x"
    value: 2.3
  - name: "c"
    value: false
messages:
  - name: "User"
interfaces:
  - name: "some_service"

4:6[35] expected value @literal=pancake
5:2[44] expected = @literal=x
5:10[52] expected const name @literal=5
9:14[81] expected value @literal=pancake
```

# bad const

```pactum
pact meshapi.gateway

const (
	b = [ 1 2 pancake ]
	a = {
		"other_key": [ 1 2
		"some_key": false
	}
    b = 2.3
	c = false
)

interface some_service {}

message User {}
```

```yaml
pact: "meshapi.gateway"
constants:
  - name: "b"
    value:
      - 1
      - 2
  - name: "a"
    value:
      key: "other_key"
      value:
        - 1
        - 2
        - "some_key"
        - false
  - name: "b"
    value: 2.3
  - name: "c"
    value: false
messages:
  - name: "User"
interfaces:
  - name: "some_service"

4:12[41] expected value @literal=pancake
7:13[91] expected value @literal=:
8:2[100] expected value @literal=}
```

# bad const - nested scope

```pactum
pact meshapi.gateway

const (
	b = [ 1 2 pancake ]
	a = {
		"other_key": {
			"nested_scope": [1 2
		},
		"some_key": false
	}
	b = 2.3
	c = false
)

interface some_service {}

message User {}
```

```yaml
pact: "meshapi.gateway"
constants:
  - name: "b"
    value:
      - 1
      - 2
  - name: "a"
    value:
      key: "other_key"
      value:
        key: "nested_scope"
        value:
          - 1
          - 2
      key: "some_key"
      value: false
  - name: "b"
    value: 2.3
  - name: "c"
    value: false
messages:
  - name: "User"
interfaces:
  - name: "some_service"

4:12[41] expected value @literal=pancake
8:3[101] expected value @literal=}
```

# bad const - invalid closing

```pactum
pact meshapi.gateway

const SomeValue = {
	"array": [1 2)
}

interface some_service {}

message User {}
```

```yaml
pact: "meshapi.gateway"
constants:
  - name: "SomeValue"
    value:
      key: "array"
      value:
        - 1
        - 2
messages:
  - name: "User"
interfaces:
  - name: "some_service"

4:15[56] expected value @literal=)
5:1[58-59] unexpected token @literal=}
```

# bad const - invalid closing - one line apart

```pactum
pact meshapi.gateway

const SomeValue = {
	"array": [1 2)
}
interface some_service {}
```

```yaml
pact: "meshapi.gateway"
constants:
  - name: "SomeValue"
    value:
      key: "array"
      value:
        - 1
        - 2
interfaces:
  - name: "some_service"

4:15[56] expected value @literal=)
5:1[58-59] unexpected token @literal=}
```

# bad const - ignored scoping after unexpected token

```pactum
pact meshapi.gateway

const SomeValue = {
	"array": [1 2 pancake (false true 1 2 {} []) false
}
interface some_service {}
```

```yaml
pact: "meshapi.gateway"
constants:
  - name: "SomeValue"
    value:
      key: "array"
      value:
        - 1
        - 2
        - false
interfaces:
  - name: "some_service"

4:16[57] expected value @literal=pancake
5:1[94] expected value @literal=}
```

# bad const - comma

```pactum
pact meshapi.gateway

const SomeValue = {
	"array": [1 2 pancake, 3 (false true 1 2 {} []), false,
}
interface some_service {}
```

```yaml
pact: "meshapi.gateway"
constants:
  - name: "SomeValue"
    value:
      key: "array"
      value:
        - 1
        - 2
        - 3
        - false
interfaces:
  - name: "some_service"

4:16[57] expected value @literal=pancake
4:27[68] expected value @literal=(
5:1[99] expected value @literal=}
```

# bad const - options

```pactum
pact meshapi.gateway

const SomeValue = {
	"array": [1 2 pancake
} { required, json.name = pancake, optional )
interface some_service {}
```

```yaml
pact: "meshapi.gateway"
constants:
  - name: "SomeValue"
    value:
      key: "array"
      value:
        - 1
        - 2
    options:
      - raw: false
        private: false
        selector: "required"
        value: true
      - raw: false
        private: false
        selector: "pancake"
        value: true
      - raw: false
        private: false
        selector: "optional"
        value: true
interfaces:
  - name: "some_service"

4:16[57] expected value @literal=pancake
5:27[91] expected value @literal=pancake
5:45[109] expected option identifier or key @literal=)
```

# const group EOF

```pact
const (
    A = "1"
    B = {
        "key": "value",
```

```yaml
constants:
  - name: "A"
    value: "1"
  - name: "B"
    value:
      key: "key"
      value: "value"

0:0[0] unexpected end of file @literal=
```

# const EOF

```pact
const B = {
    "key": "value",
```

```yaml
constants:
  - name: "B"
    value:
      key: "key"
      value: "value"

0:0[0] unexpected end of file @literal=
```

# bad enum: invalid name token

```pactum
pact meshapi.gateway

enum SomeEnum {
	Unknown = 0,
	"One",
	Two
}

interface some_service {}

message User {}
```

```yaml
pact: "meshapi.gateway"
enums:
  - name: "SomeEnum"
    variants:
      - name: "Unknown"
        value: 0
      - name: "Two"
messages:
  - name: "User"
interfaces:
  - name: "some_service"

5:2[53-58] unexpected token @literal="One"
```

# bad enum: invalid name token, same line

```pactum
pact meshapi.gateway

enum SomeEnum { Unknown = 0, "One", Two }

interface some_service {}

message User {}
```

```yaml
pact: "meshapi.gateway"
enums:
  - name: "SomeEnum"
    variants:
      - name: "Unknown"
        value: 0
      - name: "Two"
messages:
  - name: "User"
interfaces:
  - name: "some_service"

3:30[51-56] unexpected token @literal="One"
```

# bad enum: invalid variant

```pactum
pact meshapi.gateway

enum SomeEnum {
  Unknown = zero,
	"One",
	Two
}

interface some_service {}

message User {}
```

```yaml
pact: "meshapi.gateway"
enums:
  - name: "SomeEnum"
    variants:
      - name: "Unknown"
      - name: "Two"
messages:
  - name: "User"
interfaces:
  - name: "some_service"

4:13[50] expected enum variant numerical value @literal=zero
5:2[57-62] unexpected token @literal="One"
```

# bad enum: invalid variant with options

```pactum
pact meshapi.gateway

enum SomeEnum {
  Unknown = zero #required,
	"One",
	Two = 3 bad stuff #optional { some_flag, invalid_option = bad },
	Three #optional { invalid, some_option
}

interface some_service {}

message User {}
```

```yaml
pact: "meshapi.gateway"
enums:
  - name: "SomeEnum"
    variants:
      - name: "Unknown"
        options:
          - raw: false
            private: false
            selector: "required"
            value: true
      - name: "Two"
        value: 3
        options:
          - raw: false
            private: false
            selector: "optional"
            block:
              - raw: false
                private: false
                selector: "some_flag"
                value: true
              - raw: false
                private: false
                selector: "bad"
                value: true
      - name: "Three"
        options:
          - raw: false
            private: false
            selector: "optional"
            block:
              - raw: false
                private: false
                selector: "invalid"
                value: true
              - raw: false
                private: false
                selector: "some_option"
                value: true
messages:
  - name: "User"

4:13[50] expected enum variant numerical value @literal=zero
5:2[67-72] unexpected token @literal="One"
6:10[83] expected option setting modifier or end of statement @literal=bad
6:60[133] expected value @literal=bad
10:1[183] expected option setting modifier or end of statement @literal=interface
10:11[193-205] unexpected token @literal=some_service
```

# bad enum no comma

> in case comma is omitted.

```pactum
enum VariableType {
    Dynamic = 1
    Static = 2
}
```

```yaml
enums:
  - name: "VariableType"
    variants:
      - name: "Dynamic"
        value: 1
      - name: "Static"
        value: 2

3:5[40] expected option setting modifier or end of statement @literal=Static
```

# bad enum EOF

```pactum
enum UserType {
    A,
    B,
```

```yaml
enums:
  - name: "UserType"
    variants:
      - name: "A"
      - name: "B"

0:0[0] unexpected end of file @literal=
```

# message no comma

```pactum
message User {
    name: string
    age:  i32
}
```

```yaml
messages:
  - name: "User"
    fields:
      - name: "name"
        type: "string"
        nullable: false
      - name: "age"
        type: "i32"
        nullable: false

3:5[36] expected option setting modifier or end of statement @literal=age
```

# message poorly closed array option inside option block

```pactum
message User {
    name: string,
    age:  i32,

    #some_option {
        value = [1
    }
}
```

```yaml
messages:
  - name: "User"
    options:
      - raw: false
        private: false
        selector: "some_option"
        block:
          - raw: false
            private: false
            selector: "value"
            value:
              - 1
    fields:
      - name: "name"
        type: "string"
        nullable: false
      - name: "age"
        type: "i32"
        nullable: false

7:5[91] expected value @literal=}
```

# message bad oneof block

> [!NOTE] unnamed oneof block and bad scope for the second oneof block and multiple commas

```pactum
message (
	UpdateUserRequest {
        id: string,
        oneof {
            some_field: i32,
            #ignore
        },
        oneof user_change {
            name: string
            age: string,
            location: list<myapi.Location #openapi.summary="The new location for the user"
            new_field: i32,,,,

            #required
        }
	}
)
```

```yaml
messages:
  - name: "UpdateUserRequest"
    oneof_groups:
      - name: "user_change"
        options:
          - raw: false
            private: false
            selector: "required"
            value: true
    fields:
      - name: "id"
        type: "string"
        nullable: false
      - name: "name"
        type: "string"
        nullable: false
        oneof_group_index: 0
      - name: "age"
        type: "string"
        nullable: false
        oneof_group_index: 0
      - name: "new_field"
        type: "i32"
        nullable: false
        oneof_group_index: 0

4:15[65] expected oneof group name @literal={
10:13[192] expected option setting modifier or end of statement @literal=age
11:43[247] expected > @literal=#
```

# comma in message body

```pactum
message Name {
    ,,,,,
    bad_type: "some type" #optional,
    age: i32
    another_bad_field_with_no_comma: 1.2 #some_option
    field: i32,

    #required
}
```

```yaml
messages:
  - name: "Name"
    options:
      - raw: false
        private: false
        selector: "required"
        value: true
    fields:
      - name: "age"
        type: "i32"
        nullable: false
      - name: "field"
        type: "i32"
        nullable: false

3:15[39] expected field type @literal="some type"
5:5[79] expected option setting modifier or end of statement @literal=another_bad_field_with_no_comma
5:38[112] expected field type @literal=1.2
```

# message with bad closure of oneof block

```pactum
message (
    User {
        name: string,
        some_field: oneof {
            items: list<string
    }
)
```

```yaml
messages:
  - name: "User"
    fields:
      - name: "name"
        type: "string"
        nullable: false
      - name: "some_field"
        type: "oneof"
        nullable: false

6:5[106] expected > @literal=}
7:1[108] expected option setting modifier or end of statement @literal=)
0:0[0] unexpected end of file @literal=
```

# array values

```pactum
message A {
    #a.b = {
        "data": [1,,,,,2]
    }
}
```

```yaml
messages:
  - name: "A"
    options:
      - raw: false
        private: false
        selector: "a.b"
        value:
          key: "data"
          value:
            - 1
            - 2
```
