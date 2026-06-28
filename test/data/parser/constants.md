# simple string

```pactum
const name = "Pancake"
```

```yaml
constants:
  - name: "name"
    range: "1:7-23[6-22]"
    value:
      range: "1:14-23[13-22]"
      data: "Pancake"
```

# simple number with options

```pactum
const name = 1 { required }
```

```yaml
constants:
  - name: "name"
    range: "1:7-28[6-27]"
    value:
      range: "1:14-15[13-14]"
      data: 1
    annotations:
      block:
        - range: "1:18-26[17-25]"
          key_path:
            content: "required"
            range: "1:18-26[17-25]"
          value:
            range: "1:18-26[17-25]"
            data: true
```

# const group

```pactum
const (
	items = ["a" 1 false] { ignore = false }
	object = {
		"name": "something"
	} { ignore = true }
	pi = 3.14
)
```

```yaml
constants:
  - name: "items"
    range: "2:2-42[9-49]"
    value:
      range: "2:10-23[17-30]"
      data:
        - range: "2:11-14[18-21]"
          data: "a"
        - range: "2:15-16[22-23]"
          data: 1
        - range: "2:17-22[24-29]"
          data: false
    annotations:
      block:
        - range: "2:26-40[33-47]"
          key_path:
            content: "ignore"
            range: "2:26-32[33-39]"
          value:
            range: "2:35-40[42-47]"
            data: false
  - name: "object"
    range: "3:2-5:21[51-104]"
    value:
      range: "3:11-5:3[60-86]"
      data:
        key: "name"
        value:
          range: "4:11-22[72-83]"
          data: "something"
    annotations:
      block:
        - range: "5:6-19[89-102]"
          key_path:
            content: "ignore"
            range: "5:6-12[89-95]"
          value:
            range: "5:15-19[98-102]"
            data: true
  - name: "pi"
    range: "6:2-11[106-115]"
    value:
      range: "6:7-11[111-115]"
      data: 3.14
```
