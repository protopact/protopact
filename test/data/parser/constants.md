# simple string

```pactum
const name = "Pancake"
```

```yaml
options:
constants:
  - name: "name"
    range: "1:7[6-22]"
    value:
      range: "1:14[13-22]"
      data: "Pancake"
    options:
```

# simple number with options

```pactum
const name = 1 { required }
```

```yaml
options:
constants:
  - name: "name"
    range: "1:7[6-27]"
    value:
      range: "1:14[13-14]"
      data: 1
    options:
      - raw: false
        private: false
        range: "1:18[17-25]"
        selector:
          content: "required"
          range: "1:18[17-25]"
        value:
          range: "1:18[17-25]"
          data: true
```

# const group

```pactum
const (
	items = ["a" 1 false] { ignore = false }
	object = {
		"name" = "something"
	} { ignore = true }
	pi = 3.14
)
```

```yaml
options:
constants:
  - name: "items"
    range: "2:2[9-49]"
    value:
      range: "2:10[17-30]"
      data:
        - range: "2:11[18-21]"
          data: "a"
        - range: "2:15[22-23]"
          data: 1
        - range: "2:17[24-29]"
          data: false
    options:
      - raw: false
        private: false
        range: "2:26[33-47]"
        selector:
          content: "ignore"
          range: "2:26[33-39]"
        value:
          range: "2:35[42-47]"
          data: false
  - name: "object"
    range: "3:2[51-105]"
    value:
      range: "3:11[60-87]"
      data:
        key: "name"
        value:
          range: "4:12[73-84]"
          data: "something"
    options:
      - raw: false
        private: false
        range: "5:6[90-103]"
        selector:
          content: "ignore"
          range: "5:6[90-96]"
        value:
          range: "5:15[99-103]"
          data: true
  - name: "pi"
    range: "6:2[107-116]"
    value:
      range: "6:7[112-116]"
      data: 3.14
    options:
```
