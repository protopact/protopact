# simple definition

```pactum
option for Pact {
	export_files: bool
}
```

```yaml
options:
option_definitions:
  - targets:
      - Pact
    range: "1:1[0-39]"
    fields:
      - name: "export_files"
        range: "2:2[19-37]"
        type: "bool"
        type_range: "2:16[33-37]"
        tag: null
        options:
```

# multiple targets

```pactum
option for Pact, Interface, Func {
	export_files: bool = 1 #optional,
	either_this_or_that: oneof {
		this: bool,
		that: list<wellknown.Timestamp>
	}
}
```

```yaml
options:
option_definitions:
  - targets:
      - Pact
      - Interface
      - Func
    range: "1:1[0-152]"
    fields:
      - name: "export_files"
        range: "2:2[36-68]"
        type: "bool"
        type_range: "2:16[50-54]"
        tag: 1
        options:
          - raw: false
            private: false
            range: "2:26[60-68]"
            selector:
              content: "optional"
              range: "2:26[60-68]"
            value:
              range: "2:26[60-68]"
              data: true
      - name: "either_this_or_that"
        range: "3:2[71-150]"
        type: "oneof"
        oneof_options:
        oneof_fields:
          - name: "this"
            range: "4:3[102-112]"
            type: "bool"
            type_range: "4:9[108-112]"
            tag: null
            options:
          - name: "that"
            range: "5:3[116-147]"
            type: "list[item=wellknown.Timestamp]"
            type_range: "5:9[122-147]"
            tag: null
            options:
        type_range: "3:23[92-150]"
        tag: null
        options:
```

# no for, no target

```pactum
option {
	export_files: bool = 1 #optional,
}
```

```yaml
options:
option_definitions:

1:8[7] expected for @literal={
```

# no target

```pactum
option for {
	export_files: bool = 1 #optional,
}
```

```yaml
options:
option_definitions:

1:12[11] expected option target @literal={
```

# bad comma

```pactum
option for Enum, {
	export_files: bool = 1 #optional,
}
```

```yaml
options:
option_definitions:

1:18[17] expected option target @literal={
```

# bad comma

```pactum
option for Enum {
	export_files: bool = 1 #optional,
```

```yaml
options:
option_definitions:

0:0[0] unexpected end of file @literal=
```
