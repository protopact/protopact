# empty struct

```pragma
struct User {
}
```

```yaml
structs:
  - name: "User"
    range: "1:8-2:2[7-15]"
```

# simple struct

```pragma
struct User {
  name: string
}
```

```yaml
structs:
  - name: "User"
    range: "1:8-3:2[7-30]"
    members:
      - name: "name"
        range: "2:3-15[16-28]"
        type: "string"
        type_range: "2:9-15[22-28]"
```

# embedded struct with options

```pragma
struct User {
	p#openapi {
		description = "You know, a user"
	}

	embed Meta,

    name: string,
	age: u32 #optional,
}
```

```yaml
structs:
  - name: "User"
    range: "1:8-10:2[7-120]"
    annotations:
      - private: true
        range: "2:2-4:3[15-64]"
        key_path:
          content: "openapi"
          range: "2:4-11[17-24]"
        block:
          - range: "3:3-35[29-61]"
            key_path:
              content: "description"
              range: "3:3-14[29-40]"
            value:
              range: "3:17-35[43-61]"
              data: "You know, a user"
    members:
      - embed:
          content: "Meta"
          range: "6:8-12[73-77]"
      - name: "name"
        range: "8:5-17[84-96]"
        type: "string"
        type_range: "8:11-17[90-96]"
      - name: "age"
        range: "9:2-20[99-117]"
        type: "u32"
        type_range: "9:7-10[104-107]"
        annotations:
          - range: "9:12-20[109-117]"
            key_path:
              content: "optional"
              range: "9:12-20[109-117]"
            value:
              range: "9:12-20[109-117]"
              data: true
```

# oneof test

```pragma
struct User {
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
structs:
  - name: "User"
    range: "1:8-19:2[7-371]"
    annotations:
      - private: true
        range: "2:4-55[17-68]"
        key_path:
          content: "openapi.external_doc"
          range: "2:4-24[17-37]"
        value:
          range: "2:27-55[40-68]"
          data: "https://github.com/meshapi"
    oneof_groups:
      - name: "some_field"
        range: "8:5-12:3[156-242]"
        annotations:
          - range: "9:10-25[184-199]"
            key_path:
              content: "some_option"
              range: "9:10-21[184-195]"
            value:
              range: "9:24-25[198-199]"
              data: 1
    members:
      - embed:
          content: "Meta"
          range: "3:8-12[76-80]"
      - embed:
          content: "WithoutComma"
          range: "4:8-20[89-101]"
      - name: "name"
        range: "6:5-17[108-120]"
        type: "string"
        type_range: "6:11-17[114-120]"
      - name: "work"
        range: "7:2-29[123-150]"
        type: "workv1.Work"
        type_range: "7:8-19[129-140]"
        annotations:
          - range: "7:21-29[142-150]"
            key_path:
              content: "optional"
              range: "7:21-29[142-150]"
            value:
              range: "7:21-29[142-150]"
              data: true
      - name: "field_one"
        range: "11:9-39[209-239]"
        type: "wellknown.Timestamp"
        type_range: "11:20-39[220-239]"
        oneof_group_index: 0
      - name: "another_field"
        range: "13:2-18:3[244-369]"
        type: oneof
        oneof_options:
          - range: "14:4-25[270-291]"
            key_path:
              content: "some_other_option"
              range: "14:4-21[270-287]"
            value:
              range: "14:24-25[290-291]"
              data: 2
        oneof_fields:
          - name: "list"
            range: "16:4-36[296-328]"
            type: "list[item=wellknown.Timestamp]"
            type_range: "16:11-36[303-328]"
          - name: "map_field"
            range: "17:3-37[332-366]"
            type: "map[key=string, value=types.User]"
            type_range: "17:14-37[343-366]"
        type_range: "13:17-18:3[259-369]"
```

# Nullable Fields

```pragma
struct Request {
    id: string,
    updateSomething: ?string = 1000 #json.ignore,
}
```

```yaml
structs:
  - name: "Request"
    range: "1:8-4:2[7-84]"
    members:
      - name: "id"
        range: "2:5-15[21-31]"
        type: "string"
        type_range: "2:9-15[25-31]"
      - name: "updateSomething"
        range: "3:5-49[37-81]"
        type: "string"
        type_range: "3:23-29[55-61]"
        tag: 1000
        nullable: true
        annotations:
          - range: "3:38-49[70-81]"
            key_path:
              content: "json.ignore"
              range: "3:38-49[70-81]"
            value:
              range: "3:38-49[70-81]"
              data: true
```

# struct annotations with profiles

```pragma
struct (
    User {
        px[midlayer]# "org.mycoolorg/ref" = "https://mycoolorg.org/docs/users"

        id: u20 p[internal]#json.name = "$_id",
        name: string p[internal]#openapi {
            external_uri = "https://mycoolorg.org/docs/ref=user_name_v1"
        }
    }
)
```

```yaml
structs:
  - name: "User"
    range: "2:5-9:6[13-279]"
    annotations:
      - extra: true
        private: true
        profiles:
          - "midlayer"
        range: "3:23-79[42-98]"
        key_path:
          content: "org.mycoolorg/ref"
          range: "3:23-42[42-61]"
        value:
          range: "3:45-79[64-98]"
          data: "https://mycoolorg.org/docs/users"
    members:
      - name: "id"
        range: "5:9-47[108-146]"
        type: "u20"
        type_range: "5:13-16[112-115]"
        annotations:
          - private: true
            profiles:
              - "internal"
            range: "5:29-47[128-146]"
            key_path:
              content: "json.name"
              range: "5:29-38[128-137]"
            value:
              range: "5:41-47[140-146]"
              data: "$_id"
      - name: "name"
        range: "6:9-8:10[156-273]"
        type: "string"
        type_range: "6:15-21[162-168]"
        annotations:
          - private: true
            profiles:
              - "internal"
            range: "6:33-8:10[180-273]"
            key_path:
              content: "openapi"
              range: "6:34-41[181-188]"
            block:
              - range: "7:13-73[203-263]"
                key_path:
                  content: "external_uri"
                  range: "7:13-25[203-215]"
                value:
                  range: "7:28-73[218-263]"
                  data: "https://mycoolorg.org/docs/ref=user_name_v1"
```
