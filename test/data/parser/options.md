# simple flag

```pactum
#required
```

```yaml
options:
  - raw: false
    private: false
    range: "1:2[1-9]"
    selector:
      content: "required"
      range: "1:2[1-9]"
    value:
      range: "1:2[1-9]"
      data: true
```

# shared flag

```pactum
p#optional
```

```yaml
options:
  - raw: false
    private: true
    range: "1:3[2-10]"
    selector:
      content: "optional"
      range: "1:3[2-10]"
    value:
      range: "1:3[2-10]"
      data: true
```

# raw shared flag

```pactum
r#optional
```

```yaml
options:
  - raw: true
    private: false
    range: "1:3[2-10]"
    selector:
      content: "optional"
      range: "1:3[2-10]"
    value:
      range: "1:3[2-10]"
      data: true
```

# raw shared flag (string)

```pactum
r#"optional"
```

```yaml
options:
  - raw: true
    private: false
    range: "1:3[2-12]"
    selector:
      content: "optional"
      range: "1:3[2-12]"
    value:
      range: "1:3[2-12]"
      data: true
```

# raw shared flag - complex string (string)

```pactum
r#"com.pancake.io/optional"
```

```yaml
options:
  - raw: true
    private: false
    range: "1:3[2-27]"
    selector:
      content: "com.pancake.io/optional"
      range: "1:3[2-27]"
    value:
      range: "1:3[2-27]"
      data: true
```

# raw without indicating raw

```pactum
#"something"
```

```yaml
options:
  - raw: false
    private: false
    range: "1:2[1-12]"
    selector:
      content: "something"
      range: "1:2[1-12]"
    value:
      range: "1:2[1-12]"
      data: true

1:2[1-12] use of raw identifier without raw modifier prefix, did you mean to use r# ? @literal="something"
```

# string assignment

```pactum
p#json.name = "Pancake"
```

```yaml
options:
  - raw: false
    private: true
    range: "1:3[2-23]"
    selector:
      content: "json.name"
      range: "1:3[2-11]"
    value:
      range: "1:15[14-23]"
      data: "Pancake"
```

# number assignment

```pactum
p#json.`option` = 256
```

```yaml
options:
  - raw: false
    private: true
    range: "1:3[2-21]"
    selector:
      content: "json.option"
      range: "1:3[2-14]"
    value:
      range: "1:19[18-21]"
      data: 256
```

# float assignment

```pactum
#`message` = 1.592
```

```yaml
options:
  - raw: false
    private: false
    range: "1:2[2-18]"
    selector:
      content: "message"
      range: "1:2[2-9]"
    value:
      range: "1:14[13-18]"
      data: 1.592
```

# bool assignment (true)

```pactum
#required = true
```

```yaml
options:
  - raw: false
    private: false
    range: "1:2[1-16]"
    selector:
      content: "required"
      range: "1:2[1-9]"
    value:
      range: "1:13[12-16]"
      data: true
```

# bool assignment (false)

```pactum
#optional = false
```

```yaml
options:
  - raw: false
    private: false
    range: "1:2[1-17]"
    selector:
      content: "optional"
      range: "1:2[1-9]"
    value:
      range: "1:13[12-17]"
      data: false
```

# array string

```pactum
#items = ["a" "b" "c"]
r#items.with.comma = ["a", "b", "c"]
p#`items` = [
	"a",
	"b",
	"c",
]
```

```yaml
options:
  - raw: false
    private: false
    range: "1:2[1-22]"
    selector:
      content: "items"
      range: "1:2[1-6]"
    value:
      range: "1:10[9-22]"
      data:
        - range: "1:11[10-13]"
          data: "a"
        - range: "1:15[14-17]"
          data: "b"
        - range: "1:19[18-21]"
          data: "c"
  - raw: true
    private: false
    range: "2:3[25-59]"
    selector:
      content: "items.with.comma"
      range: "2:3[25-41]"
    value:
      range: "2:22[44-59]"
      data:
        - range: "2:23[45-48]"
          data: "a"
        - range: "2:28[50-53]"
          data: "b"
        - range: "2:33[55-58]"
          data: "c"
  - raw: false
    private: true
    range: "3:3[63-93]"
    selector:
      content: "items"
      range: "3:3[63-68]"
    value:
      range: "3:13[72-93]"
      data:
        - range: "4:2[75-78]"
          data: "a"
        - range: "5:2[81-84]"
          data: "b"
        - range: "6:2[87-90]"
          data: "c"
```

# array mixed

```pactum
#items = [1 false 1.4 ["a" "b"] "c"]
```

```yaml
options:
  - raw: false
    private: false
    range: "1:2[1-36]"
    selector:
      content: "items"
      range: "1:2[1-6]"
    value:
      range: "1:10[9-36]"
      data:
        - range: "1:11[10-11]"
          data: 1
        - range: "1:13[12-17]"
          data: false
        - range: "1:19[18-21]"
          data: 1.4
        - range: "1:23[22-31]"
          data:
            - range: "1:24[23-26]"
              data: "a"
            - range: "1:28[27-30]"
              data: "b"
        - range: "1:33[32-35]"
          data: "c"
```

# object

```pactum
#items = { "name" = "Pancake", "kind" = "food", "id" = 1 }
```

```yaml
options:
  - raw: false
    private: false
    range: "1:2[1-58]"
    selector:
      content: "items"
      range: "1:2[1-6]"
    value:
      range: "1:10[9-58]"
      data:
        key: "name"
        value:
          range: "1:21[20-29]"
          data: "Pancake"
        key: "kind"
        value:
          range: "1:41[40-46]"
          data: "food"
        key: "id"
        value:
          range: "1:56[55-56]"
          data: 1
```

# complex everything #1

```pactum
r#"com.meshapi:meta" = {
	"required" = true,
	"no comma" = 1
	"array" = [1 2 3]
	"object" = {
		"nested object" = {
			"nested array" = [
				1
				2.3
				true
				{ "name" = "Pancake" }
			]
		}
	}
}
```

```yaml
options:
  - raw: true
    private: false
    range: "1:3[2-201]"
    selector:
      content: "com.meshapi:meta"
      range: "1:3[2-20]"
    value:
      range: "1:24[23-201]"
      data:
        key: "required"
        value:
          range: "2:15[39-43]"
          data: true
        key: "no comma"
        value:
          range: "3:15[59-60]"
          data: 1
        key: "array"
        value:
          range: "4:12[72-79]"
          data:
            - range: "4:13[73-74]"
              data: 1
            - range: "4:15[75-76]"
              data: 2
            - range: "4:17[77-78]"
              data: 3
        key: "object"
        value:
          range: "5:13[92-199]"
          data:
            key: "nested object"
            value:
              range: "6:21[114-196]"
              data:
                key: "nested array"
                value:
                  range: "7:21[136-192]"
                  data:
                    - range: "8:5[142-143]"
                      data: 1
                    - range: "9:5[148-151]"
                      data: 2.3
                    - range: "10:5[156-160]"
                      data: true
                    - range: "11:5[165-187]"
                      data:
                        key: "name"
                        value:
                          range: "11:16[176-185]"
                          data: "Pancake"
```

# option block

```pactum
r#"com.meshapi" {
	name = "Pancake"
	p#required,
	id = 12
}
```

```yaml
options:
  - raw: true
    private: false
    range: "1:3[2-59]"
    selector:
      content: "com.meshapi"
      range: "1:3[2-15]"
    block:
      - raw: false
        private: false
        range: "2:2[19-35]"
        selector:
          content: "name"
          range: "2:2[19-23]"
        value:
          range: "2:9[26-35]"
          data: "Pancake"
      - raw: false
        private: true
        range: "3:4[39-47]"
        selector:
          content: "required"
          range: "3:4[39-47]"
        value:
          range: "3:4[39-47]"
          data: true
      - raw: false
        private: false
        range: "4:2[50-57]"
        selector:
          content: "id"
          range: "4:2[50-52]"
        value:
          range: "4:7[55-57]"
          data: 12
```

# root level block

```pactum
p# {
	name = "Pancake"
	r#required,
	id = 12
}
```

```yaml
options:
  - raw: false
    private: true
    range: "1:4[3-46]"
    selector:
      content: ""
      range: "0:0[0-0]"
    block:
      - raw: false
        private: false
        range: "2:2[6-22]"
        selector:
          content: "name"
          range: "2:2[6-10]"
        value:
          range: "2:9[13-22]"
          data: "Pancake"
      - raw: true
        private: false
        range: "3:4[26-34]"
        selector:
          content: "required"
          range: "3:4[26-34]"
        value:
          range: "3:4[26-34]"
          data: true
      - raw: false
        private: false
        range: "4:2[37-44]"
        selector:
          content: "id"
          range: "4:2[37-39]"
        value:
          range: "4:7[42-44]"
          data: 12
```
