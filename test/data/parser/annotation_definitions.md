# simple definition

```pragma
annotation for Package {
    export_files: bool
}
```

```yaml
annotation_definitions:
  - targets:
      - Package
    range: "1:1-3:2[0-49]"
    members:
      - name: "export_files"
        range: "2:5-23[29-47]"
        type: "bool"
        type_range: "2:19-23[43-47]"
```

# multiple targets

```pragma
annotation for Package, Protocol, Func {
	export_files: bool = 1 #optional,
	either_this_or_that: oneof {
		this: bool,
		that: list<wellknown.Timestamp>
	}
}
```

```yaml
annotation_definitions:
  - targets:
      - Package
      - Protocol
      - Func
    range: "1:1-7:2[0-158]"
    members:
      - name: "export_files"
        range: "2:2-34[42-74]"
        type: "bool"
        type_range: "2:16-20[56-60]"
        tag: 1
        annotations:
          - range: "2:26-34[66-74]"
            key_path:
              content: "optional"
              range: "2:26-34[66-74]"
            value:
              range: "2:26-34[66-74]"
              data: true
      - name: "either_this_or_that"
        range: "3:2-6:3[77-156]"
        type: oneof
        oneof_fields:
          - name: "this"
            range: "4:3-13[108-118]"
            type: "bool"
            type_range: "4:9-13[114-118]"
          - name: "that"
            range: "5:3-34[122-153]"
            type: "list[item=wellknown.Timestamp]"
            type_range: "5:9-34[128-153]"
        type_range: "3:23-6:3[98-156]"
```

# no for, no target

```pragma
annotation {
	export_files: bool = 1 #optional,
}
```

```yaml
1:12-13[11-12] expected for @literal={
```

# no target

```pragma
annotation for {
	export_files: bool = 1 #optional,
}
```

```yaml
1:16-17[15-16] expected annotation target @literal={
```

# bad comma

```pragma
annotation for Enum, {
	export_files: bool = 1 #optional,
}
```

```yaml
1:22-23[21-22] expected annotation target @literal={
```

# bad comma

```pragma
annotation for Enum {
	export_files: bool = 1 #optional,
```

```yaml
annotation_definitions:
  - targets:
      - Enum
    range: "1:1-2:35[0-56]"
    members:
      - name: "export_files"
        range: "2:2-34[23-55]"
        type: "bool"
        type_range: "2:16-20[37-41]"
        tag: 1
        annotations:
          - range: "2:26-34[47-55]"
            key_path:
              content: "optional"
              range: "2:26-34[47-55]"
            value:
              range: "2:26-34[47-55]"
              data: true

0:0[0] unexpected end of file
```

# use embed

```pragma
annotation for Package {
    export_files: bool,

    embed CommonOptions
}
```

```yaml
annotation_definitions:
  - targets:
      - Package
    range: "1:1-5:2[0-75]"
    members:
      - name: "export_files"
        range: "2:5-23[29-47]"
        type: "bool"
        type_range: "2:19-23[43-47]"
      - embed:
          content: "CommonOptions"
          range: "4:11-24[60-73]"
```
