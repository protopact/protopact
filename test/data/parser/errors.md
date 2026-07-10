# invalid keypath in global scope

```pragma
import "some/package"
import "pact/http"

const A = @ref(meshapi.gateway.)

const B = @ref(meshapi.gateway..)

struct Something {
  name: string #required,
}
```

```yaml
imports:
  - path: "some/package"
  - path: "pact/http"
structs:
  - name: "Something"
    members:
      - name: "name"
        type: "string"
        annotations:
          - key_path: "required"
            value: true

4:32-33[73-74] expected keypath segment @literal=)
6:32-33[107-108] unexpected token @literal=.
```

# unterminated string literals

```pragma
import "something

protocol some_service {}
```

```yaml
imports:
  - path: "something"
protocols:
  - name: "some_service"

1:8-18[7-17] unterminated string @literal="something
```

# bad import

```pragma
import

protocol some_service {}

struct User {}
```

```yaml
structs:
  - name: "User"
protocols:
  - name: "some_service"

3:1-9[8-16] expected path string @literal=protocol
```

# unterminated import path inside import group

```pragma
import (
	# "some/unterminated/string
	some_package "some/nice/package"
)

protocol some_service {}

struct User {}
```

```yaml
imports:
  - bare: true
    path: "some/unterminated/string"
  - alias: "some_package"
    path: "some/nice/package"
structs:
  - name: "User"
protocols:
  - name: "some_service"

2:4-29[12-37] unterminated string @literal="some/unterminated/string
```

# incomplete import inside group

```pragma
import (
	_
	some_package "some/nice/package"
	another_package "some/ok/package"
)

protocol some_service {}

struct User {}
```

```yaml
imports:
  - alias: "some_package"
    path: "some/nice/package"
  - alias: "another_package"
    path: "some/ok/package"
structs:
  - name: "User"
protocols:
  - name: "some_service"

2:2-3[10-11] unexpected character @literal=_
```

# import group eof

```pragma
import (
 # "some/package"
```

```yaml
imports:
  - bare: true
    path: "some/package"

0:0[0] unexpected end of file
```

# bad const simple values

```pragma
const (
	b = pancake
	x = 2.3 5
	c = false
)

const name = pancake
protocol some_service {}

struct User {}
```

```yaml
constants:
  - name: "x"
    value: 2.3
  - name: "c"
    value: false
structs:
  - name: "User"
protocols:
  - name: "some_service"

2:6-13[13-20] expected value @literal=pancake
3:2-3[22-23] expected = @literal=x
3:10-11[30-31] expected const name @literal=5
7:14-21[59-66] expected value @literal=pancake
```

# bad const

```pragma
const (
	b = [ 1 2 pancake 3 ]
	a = {
		"other_key": [ 1 2
		"some_key": false
	}
    b = 2.3
	c = false
)

protocol some_service {}

struct User {}
```

```yaml
constants:
  - name: "b"
    value:
      - 1
      - 2
      - 3
  - name: "a"
    value:
      - key: "other_key"
        value:
          - 1
          - 2
          - "some_key"
          - false
  - name: "b"
    value: 2.3
  - name: "c"
    value: false
structs:
  - name: "User"
protocols:
  - name: "some_service"

2:12-19[19-26] expected value @literal=pancake
5:13-14[71-72] expected value @literal=:
6:2-3[80-81] expected value @literal=}
```

# bad const - nested scope

```pragma
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

protocol some_service {}

struct User {}
```

```yaml
constants:
  - name: "b"
    value:
      - 1
      - 2
  - name: "a"
    value:
      - key: "other_key"
        value:
          - key: "nested_scope"
            value:
              - 1
              - 2
      - key: "some_key"
        value: false
  - name: "b"
    value: 2.3
  - name: "c"
    value: false
structs:
  - name: "User"
protocols:
  - name: "some_service"

2:12-19[19-26] expected value @literal=pancake
6:3-4[79-80] expected value @literal=}
```

# bad const - invalid closing

```pragma
const SomeValue = {
	"array": [1 2)
}

protocol some_service {}

struct User {}
```

```yaml
constants:
  - name: "SomeValue"
    value:
      - key: "array"
        value:
          - 1
          - 2
structs:
  - name: "User"
protocols:
  - name: "some_service"

2:15-16[34-35] expected value @literal=)
3:1-2[36-37] unexpected token @literal=}
```

# bad const - ignored scoping after unexpected token

```pragma
const SomeValue = {
	"array": [1 2 pancake (false true 1 2 {} []) false
}
protocol some_service {}
```

```yaml
constants:
  - name: "SomeValue"
    value:
      - key: "array"
        value:
          - 1
          - 2
          - false
protocols:
  - name: "some_service"

2:16-23[35-42] expected value @literal=pancake
3:1-2[72-73] expected value @literal=}
```

# bad const - comma

```pragma
const SomeValue = {
	"array": [1 2 pancake, 3 (false true 1 2 {} []), false,
}
protocol some_service {}
```

```yaml
constants:
  - name: "SomeValue"
    value:
      - key: "array"
        value:
          - 1
          - 2
          - 3
          - false
protocols:
  - name: "some_service"

2:16-23[35-42] expected value @literal=pancake
2:27-28[46-47] expected value @literal=(
3:1-2[77-78] expected value @literal=}
```

# bad const - options

```pragma
const SomeValue = {
	"array": [1 2 pancake
} { required, json.name = pancake, optional )
protocol some_service {}
```

```yaml
constants:
  - name: "SomeValue"
    value:
      - key: "array"
        value:
          - 1
          - 2
    annotations:
      block:
        - key_path: "required"
          value: true
        - key_path: "pancake"
          value: true
        - key_path: "optional"
          value: true
protocols:
  - name: "some_service"

2:16-23[35-42] expected value @literal=pancake
3:27-34[69-76] expected value @literal=pancake
3:45-46[87-88] expected annotation key path or string @literal=)
```

# const group EOF

```pragma
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
      - key: "key"
        value: "value"

0:0[0] unexpected end of file
```

# const EOF

```pragma
const B = {
    "key": "value",
```

```yaml
constants:
  - name: "B"
    value:
      - key: "key"
        value: "value"

0:0[0] unexpected end of file
```

# bad enum: invalid name token

```pragma
enum SomeEnum {
	Unknown = 0,
	"One",
	Two
}

protocol some_service {}

struct User {}
```

```yaml
enums:
  - name: "SomeEnum"
    variants:
      - name: "Unknown"
        value: 0
      - name: "Two"
structs:
  - name: "User"
protocols:
  - name: "some_service"

3:2-7[31-36] unexpected token @literal="One"
```

# bad enum: invalid name token, same line

```pragma
enum SomeEnum { Unknown = 0, "One", Two }

protocol some_service {}

struct User {}
```

```yaml
enums:
  - name: "SomeEnum"
    variants:
      - name: "Unknown"
        value: 0
      - name: "Two"
structs:
  - name: "User"
protocols:
  - name: "some_service"

1:30-35[29-34] unexpected token @literal="One"
```

# bad enum: invalid variant

```pragma
enum SomeEnum {
  Unknown = zero,
	"One",
	Two
}

protocol some_service {}

struct User {}
```

```yaml
enums:
  - name: "SomeEnum"
    variants:
      - name: "Unknown"
      - name: "Two"
structs:
  - name: "User"
protocols:
  - name: "some_service"

2:13-17[28-32] expected enum variant numerical value @literal=zero
3:2-7[35-40] unexpected token @literal="One"
```

# bad enum: invalid variant with options

```pragma
enum SomeEnum {
  Unknown = zero #required,
	"One",
	Two = 3 bad stuff #optional { some_flag, invalid_option = bad },
	Three #optional { invalid, some_option
}

protocol some_service {}

struct User {}
```

```yaml
enums:
  - name: "SomeEnum"
    annotations:
      - key_path: "required"
        value: true
    variants:
      - name: "Unknown"
      - name: "Two"
        value: 3
        annotations:
          - key_path: "optional"
            block:
              - key_path: "some_flag"
                value: true
              - key_path: "bad"
                value: true
      - name: "Three"
        annotations:
          - key_path: "optional"
            block:
              - key_path: "invalid"
                value: true
              - key_path: "some_option"
                value: true

2:13-17[28-32] expected enum variant numerical value @literal=zero
3:2-7[45-50] unexpected token @literal="One"
4:10-13[61-64] expected annotation modifier or end of statement @literal=bad
4:60-63[111-114] expected value @literal=bad
8:1-9[161-169] expected annotation modifier or end of statement @literal=protocol
```

# bad enum no comma

> in case comma is omitted.

```pragma
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

3:5-11[40-46] expected annotation modifier or end of statement @literal=Static
```

# bad enum EOF

```pragma
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

0:0[0] unexpected end of file
```

# struct no comma

```pragma
struct User {
    name: string
    age:  i32
}
```

```yaml
structs:
  - name: "User"
    members:
      - name: "name"
        type: "string"

3:5-8[35-38] expected annotation modifier or end of statement @literal=age
```

# struct poorly closed array option inside option block

```pragma
struct User {
    name: string,
    age:  i32,

    #some_option {
        value = [1
    }
}
```

```yaml
structs:
  - name: "User"
    annotations:
      - key_path: "some_option"
        block:
          - key_path: "value"
            value:
              - 1
    members:
      - name: "name"
        type: "string"
      - name: "age"
        type: "i32"

7:5-6[90-91] expected value @literal=}
```

# struct bad oneof block

> [!NOTE] unnamed oneof block and bad scope for the second oneof block and multiple commas

```pragma
struct (
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
structs:
  - name: "UpdateUserRequest"
    oneof_groups:
      - name: "user_change"
        annotations:
          - key_path: "required"
            value: true
    members:
      - name: "id"
        type: "string"
      - name: "name"
        type: "string"
        oneof_group_index: 0

4:15-16[64-65] expected oneof group name @literal={
10:13-16[191-194] expected annotation modifier or end of statement @literal=age
11:43-44[246-247] expected > @literal=#
```

# comma in struct body

```pragma
struct Name {
    ,,,,,
    bad_type: "some type" #optional,
    age: i32
    another_bad_field_with_no_comma: 1.2 #some_option
    field: i32,

    #required
}
```

```yaml
structs:
  - name: "Name"
    annotations:
      - key_path: "required"
        value: true
    members:
      - name: "age"
        type: "i32"
        annotations:
          - key_path: "some_option"
            value: true

3:15-26[38-49] expected field type @literal="some type"
5:5-36[78-109] expected annotation modifier or end of statement @literal=another_bad_field_with_no_comma
6:5-10[132-137] expected annotation modifier or end of statement @literal=field
```

# struct with bad closure of oneof block

```pragma
struct (
    User {
        name: string,
        some_field: oneof {
            items: list<string
    }
)
```

```yaml
structs:
  - name: "User"
    members:
      - name: "name"
        type: "string"
      - name: "some_field"
        type: oneof

6:5-6[105-106] expected > @literal=}
7:1-2[107-108] expected annotation modifier or end of statement @literal=)
0:0[0] unexpected end of file
```

# array values

```pragma
struct A {
    #a.b = {
        "data": [1,,,,,2]
    }
}
```

```yaml
structs:
  - name: "A"
    annotations:
      - key_path: "a.b"
        value:
          - key: "data"
            value:
              - 1
              - 2
```
