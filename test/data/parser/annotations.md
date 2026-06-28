# simple modifier

```pragma
#required
```

```yaml
annotations:
  - range: "1:2-10[1-9]"
    key_path:
      content: "required"
      range: "1:2-10[1-9]"
    value:
      range: "1:2-10[1-9]"
      data: true
```

# private flag

```pragma
p#optional
```

```yaml
annotations:
  - private: true
    range: "1:3-11[2-10]"
    key_path:
      content: "optional"
      range: "1:3-11[2-10]"
    value:
      range: "1:3-11[2-10]"
      data: true
```

# extra flag

```pragma
x#optional
```

```yaml
annotations:
  - extra: true
    range: "1:3-11[2-10]"
    key_path:
      content: "optional"
      range: "1:3-11[2-10]"
    value:
      range: "1:3-11[2-10]"
      data: true
```

# extra flag (string)

```pragma
x#"optional"
```

```yaml
annotations:
  - extra: true
    range: "1:3-13[2-12]"
    key_path:
      content: "optional"
      range: "1:3-13[2-12]"
    value:
      range: "1:3-13[2-12]"
      data: true
```

# extra flag - complex string (string)

```pragma
x#"com.pancake.io/optional"
```

```yaml
annotations:
  - extra: true
    range: "1:3-28[2-27]"
    key_path:
      content: "com.pancake.io/optional"
      range: "1:3-28[2-27]"
    value:
      range: "1:3-28[2-27]"
      data: true
```

# extra annotation without x# sigil

```pragma
#"something"
```

```yaml
annotations:
  - range: "1:2-13[1-12]"
    key_path:
      content: "something"
      range: "1:2-13[1-12]"
    value:
      range: "1:2-13[1-12]"
      data: true

1:2-13[1-12] use of extra annotation (attribute) without extra modifier, did you mean to use x# ? @literal="something"

```

# private string assignment

```pragma
p#json.name = "Pancake"
```

```yaml
annotations:
  - private: true
    range: "1:3-24[2-23]"
    key_path:
      content: "json.name"
      range: "1:3-12[2-11]"
    value:
      range: "1:15-24[14-23]"
      data: "Pancake"
```

# number assignment

```pragma
p#json.`option` = 256
```

```yaml
annotations:
  - private: true
    range: "1:3-22[2-21]"
    key_path:
      content: "json.option"
      range: "1:3-15[2-14]"
    value:
      range: "1:19-22[18-21]"
      data: 256
```

# float assignment

```pragma
#`message` = 1.592
```

```yaml
annotations:
  - range: "1:3-19[2-18]"
    key_path:
      content: "message"
      range: "1:3-10[2-9]"
    value:
      range: "1:14-19[13-18]"
      data: 1.592
```

# bool assignment (true)

```pragma
#required = true
```

```yaml
annotations:
  - range: "1:2-17[1-16]"
    key_path:
      content: "required"
      range: "1:2-10[1-9]"
    value:
      range: "1:13-17[12-16]"
      data: true
```

# bool assignment (false)

```pragma
#optional = false
```

```yaml
annotations:
  - range: "1:2-18[1-17]"
    key_path:
      content: "optional"
      range: "1:2-10[1-9]"
    value:
      range: "1:13-18[12-17]"
      data: false
```

# array string

```pragma
#items = ["a" "b" "c"]
x#items.with.comma = ["a", "b", "c"]
p#`items` = [
	"a",
	"b",
	"c",
]
```

```yaml
annotations:
  - range: "1:2-23[1-22]"
    key_path:
      content: "items"
      range: "1:2-7[1-6]"
    value:
      range: "1:10-23[9-22]"
      data:
        - range: "1:11-14[10-13]"
          data: "a"
        - range: "1:15-18[14-17]"
          data: "b"
        - range: "1:19-22[18-21]"
          data: "c"
  - extra: true
    range: "2:3-37[25-59]"
    key_path:
      content: "items.with.comma"
      range: "2:3-19[25-41]"
    value:
      range: "2:22-37[44-59]"
      data:
        - range: "2:23-26[45-48]"
          data: "a"
        - range: "2:28-31[50-53]"
          data: "b"
        - range: "2:33-36[55-58]"
          data: "c"
  - private: true
    range: "3:4-7:2[63-93]"
    key_path:
      content: "items"
      range: "3:4-9[63-68]"
    value:
      range: "3:13-7:2[72-93]"
      data:
        - range: "4:2-5[75-78]"
          data: "a"
        - range: "5:2-5[81-84]"
          data: "b"
        - range: "6:2-5[87-90]"
          data: "c"
```

# array mixed

```pragma
#items = [1 false 1.4 ["a" "b"] "c"]
```

```yaml
annotations:
  - range: "1:2-37[1-36]"
    key_path:
      content: "items"
      range: "1:2-7[1-6]"
    value:
      range: "1:10-37[9-36]"
      data:
        - range: "1:11-12[10-11]"
          data: 1
        - range: "1:13-18[12-17]"
          data: false
        - range: "1:19-22[18-21]"
          data: 1.4
        - range: "1:23-32[22-31]"
          data:
            - range: "1:24-27[23-26]"
              data: "a"
            - range: "1:28-31[27-30]"
              data: "b"
        - range: "1:33-36[32-35]"
          data: "c"
```

# object

```pragma
#items = { "name": "Pancake", "kind": "food", "id": 1 }
```

```yaml
annotations:
  - range: "1:2-56[1-55]"
    key_path:
      content: "items"
      range: "1:2-7[1-6]"
    value:
      range: "1:10-56[9-55]"
      data:
        - key: "name"
          value:
            range: "1:20-29[19-28]"
            data: "Pancake"
        - key: "kind"
          value:
            range: "1:39-45[38-44]"
            data: "food"
        - key: "id"
          value:
            range: "1:53-54[52-53]"
            data: 1
```

# complex everything #1

```pragma
x#"com.meshapi:meta" = {
	"required": true,
	"no comma": 1
	"array": [1 2 3]
	"object": {
		"nested object": {
			"nested array": [
				1
				2.3
				true
				{ "name": "Pancake" }
			]
		}
	}
}
```

```yaml
annotations:
  - extra: true
    range: "1:3-15:2[2-194]"
    key_path:
      content: "com.meshapi:meta"
      range: "1:3-21[2-20]"
    value:
      range: "1:24-15:2[23-194]"
      data:
        - key: "required"
          value:
            range: "2:14-18[38-42]"
            data: true
        - key: "no comma"
          value:
            range: "3:14-15[57-58]"
            data: 1
        - key: "array"
          value:
            range: "4:11-18[69-76]"
            data:
              - range: "4:12-13[70-71]"
                data: 1
              - range: "4:14-15[72-73]"
                data: 2
              - range: "4:16-17[74-75]"
                data: 3
        - key: "object"
          value:
            range: "5:12-14:3[88-192]"
            data:
              - key: "nested object"
                value:
                  range: "6:20-13:4[109-189]"
                  data:
                    - key: "nested array"
                      value:
                        range: "7:20-12:5[130-185]"
                        data:
                          - range: "8:5-6[136-137]"
                            data: 1
                          - range: "9:5-8[142-145]"
                            data: 2.3
                          - range: "10:5-9[150-154]"
                            data: true
                          - range: "11:5-26[159-180]"
                            data:
                              - key: "name"
                                value:
                                  range: "11:15-24[169-178]"
                                  data: "Pancake"
```

# annotation block

```pragma
x#"com.meshapi" {
	name = "Pancake"
	p#required,
	id = 12
}
```

```yaml
annotations:
  - extra: true
    range: "1:1-5:2[0-59]"
    key_path:
      content: "com.meshapi"
      range: "1:3-16[2-15]"
    block:
      - range: "2:2-18[19-35]"
        key_path:
          content: "name"
          range: "2:2-6[19-23]"
        value:
          range: "2:9-18[26-35]"
          data: "Pancake"
      - private: true
        range: "3:4-12[39-47]"
        key_path:
          content: "required"
          range: "3:4-12[39-47]"
        value:
          range: "3:4-12[39-47]"
          data: true
      - range: "4:2-9[50-57]"
        key_path:
          content: "id"
          range: "4:2-4[50-52]"
        value:
          range: "4:7-9[55-57]"
          data: 12
```

# root level block

```pragma
p# {
	name = "Pancake"
	x#required,
	id = 12
}
```

```yaml
annotations:
  - private: true
    range: "1:1-5:2[0-46]"
    key_path:
      content: ""
      range: "1:1-1[0-0]"
    block:
      - range: "2:2-18[6-22]"
        key_path:
          content: "name"
          range: "2:2-6[6-10]"
        value:
          range: "2:9-18[13-22]"
          data: "Pancake"
      - extra: true
        range: "3:4-12[26-34]"
        key_path:
          content: "required"
          range: "3:4-12[26-34]"
        value:
          range: "3:4-12[26-34]"
          data: true
      - range: "4:2-9[37-44]"
        key_path:
          content: "id"
          range: "4:2-4[37-39]"
        value:
          range: "4:7-9[42-44]"
          data: 12
```
