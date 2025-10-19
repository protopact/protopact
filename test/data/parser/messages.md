# empty message

```pactum
message User {
}
```

```yaml
options:
messages:
  - name: "User"
    range: "1:9[8-16]"
    embedded_messages:
    options:
    oneof_groups:
    fields:
```

# simple message

```pactum
message User {
  name: string
}
```

```yaml
options:
messages:
  - name: "User"
    range: "1:9[8-31]"
    embedded_messages:
    options:
    oneof_groups:
    fields:
      - name: "name"
        range: "2:3[17-29]"
        type: "string"
        type_range: "2:9[23-29]"
        tag: null
        options:
```

# embedded message with options

```pactum
message User {
	p#openapi {
		description = "You know, a user"
	}

	embed Meta,

  name: string,
	age: u32 #optional,
}
```

```yaml
options:
messages:
  - name: "User"
    range: "1:9[8-119]"
    embedded_messages:
      - content: "Meta"
        range: "6:8[74-78]"
    options:
      - raw: false
        private: true
        range: "2:4[18-65]"
        selector:
          content: "openapi"
          range: "2:4[18-25]"
        block:
          - raw: false
            private: false
            range: "3:3[30-62]"
            selector:
              content: "description"
              range: "3:3[30-41]"
            value:
              range: "3:17[44-62]"
              data: "You know, a user"
    oneof_groups:
    fields:
      - name: "name"
        range: "8:3[83-95]"
        type: "string"
        type_range: "8:9[89-95]"
        tag: null
        options:
      - name: "age"
        range: "9:2[98-116]"
        type: "u32"
        type_range: "9:7[103-106]"
        tag: null
        options:
          - raw: false
            private: false
            range: "9:12[108-116]"
            selector:
              content: "optional"
              range: "9:12[108-116]"
            value:
              range: "9:12[108-116]"
              data: true
```

# oneof test

```pactum
message User {
	p#openapi.external_doc = "https://github.com/meshapi"
	embed Meta,
	embed WithoutComma,

  name: string,
	work: workv1.Work #optional,
	oneof some_field {
    #some_option = 1

	  field_one: wellknown.Timestamp
	}
	another_field: oneof {
		#some_other_option = 2

		`list`: list<wellknown.Timestamp>,
		map_field: map<string, types.User>
	}
}
```

```yaml
options:
messages:
  - name: "User"
    range: "1:9[8-358]"
    embedded_messages:
      - content: "Meta"
        range: "3:8[77-81]"
      - content: "WithoutComma"
        range: "4:8[90-102]"
    options:
      - raw: false
        private: true
        range: "2:4[18-69]"
        selector:
          content: "openapi.external_doc"
          range: "2:4[18-38]"
        value:
          range: "2:27[41-69]"
          data: "https://github.com/meshapi"
    oneof_groups:
      - name: "some_field"
        range: "8:2[152-229]"
        options:
          - raw: false
            private: false
            range: "9:6[176-191]"
            selector:
              content: "some_option"
              range: "9:6[176-187]"
            value:
              range: "9:20[190-191]"
              data: 1
    fields:
      - name: "name"
        range: "6:3[107-119]"
        type: "string"
        type_range: "6:9[113-119]"
        tag: null
        options:
      - name: "work"
        range: "7:2[122-149]"
        type: "workv1.Work"
        type_range: "7:8[128-139]"
        tag: null
        options:
          - raw: false
            private: false
            range: "7:21[141-149]"
            selector:
              content: "optional"
              range: "7:21[141-149]"
            value:
              range: "7:21[141-149]"
              data: true
      - name: "field_one"
        range: "11:4[196-226]"
        type: "wellknown.Timestamp"
        type_range: "11:15[207-226]"
        tag: null
        oneof_group_index: 0
        options:
      - name: "another_field"
        range: "13:2[231-356]"
        type: "oneof"
        oneof_options:
          - raw: false
            private: false
            range: "14:4[257-278]"
            selector:
              content: "some_other_option"
              range: "14:4[257-274]"
            value:
              range: "14:24[277-278]"
              data: 2
        oneof_fields:
          - name: "list"
            range: "16:3[283-315]"
            type: "list[item=wellknown.Timestamp]"
            type_range: "16:11[290-315]"
            tag: null
            options:
          - name: "map_field"
            range: "17:3[319-353]"
            type: "map[key=string, value=types.User]"
            type_range: "17:14[330-353]"
            tag: null
            options:
        type_range: "13:17[246-356]"
        tag: null
        options:
```
