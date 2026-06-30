# one liner

```pragma
enum Color { Red, Green, Blue }
```

```yaml
enums:
  - name: "Color"
    range: "1:6-32[5-31]"
    variants:
      - name: "Red"
        range: "1:14-17[13-16]"
      - name: "Green"
        range: "1:19-24[18-23]"
      - name: "Blue"
        range: "1:26-30[25-29]"
```

# value assignment and variant annotations

```pragma
enum Color { Red = 1, Green #required, Blue = 51 p#ignore x#"meshapi.io:name" = "b" }
```

```yaml
enums:
  - name: "Color"
    range: "1:6-86[5-85]"
    variants:
      - name: "Red"
        range: "1:14-21[13-20]"
        value: 1
      - name: "Green"
        range: "1:23-38[22-37]"
        annotations:
          - range: "1:30-38[29-37]"
            key_path:
              content: "required"
              range: "1:30-38[29-37]"
            value:
              range: "1:30-38[29-37]"
              data: true
      - name: "Blue"
        range: "1:40-84[39-83]"
        value: 51
        annotations:
          - private: true
            range: "1:52-58[51-57]"
            key_path:
              content: "ignore"
              range: "1:52-58[51-57]"
            value:
              range: "1:52-58[51-57]"
              data: true
          - extra: true
            range: "1:61-84[60-83]"
            key_path:
              content: "meshapi.io:name"
              range: "1:61-78[60-77]"
            value:
              range: "1:81-84[80-83]"
              data: "b"
```

# enum annotations

```pragma
enum Color {
  p#openapi {
		description = "Represents an RGB color."
	}

	#cpp {
		prefix = "COLOR"
	}

	Unknown = 0 #ignore,
	Red,
	Blue,
	Green,
}
```

```yaml
enums:
  - name: "Color"
    range: "1:6-14:2[5-149]"
    annotations:
      - private: true
        range: "2:3-4:3[15-72]"
        key_path:
          content: "openapi"
          range: "2:5-12[17-24]"
        block:
          - range: "3:3-43[29-69]"
            key_path:
              content: "description"
              range: "3:3-14[29-40]"
            value:
              range: "3:17-43[43-69]"
              data: "Represents an RGB color."
      - range: "6:2-8:3[75-103]"
        key_path:
          content: "cpp"
          range: "6:3-6[76-79]"
        block:
          - range: "7:3-19[84-100]"
            key_path:
              content: "prefix"
              range: "7:3-9[84-90]"
            value:
              range: "7:12-19[93-100]"
              data: "COLOR"
    variants:
      - name: "Unknown"
        range: "10:2-21[106-125]"
        value: 0
        annotations:
          - range: "10:15-21[119-125]"
            key_path:
              content: "ignore"
              range: "10:15-21[119-125]"
            value:
              range: "10:15-21[119-125]"
              data: true
      - name: "Red"
        range: "11:2-5[128-131]"
      - name: "Blue"
        range: "12:2-6[134-138]"
      - name: "Green"
        range: "13:2-7[141-146]"
```

# enum group

```pragma
enum ()
enum (
	Color { Red, Green, Blue }
	Mood {
		Unsure = 0,
		Happy,
		Sad,
		Excited,
	}
)
```

```yaml
enums:
  - name: "Color"
    range: "3:2-28[16-42]"
    variants:
      - name: "Red"
        range: "3:10-13[24-27]"
      - name: "Green"
        range: "3:15-20[29-34]"
      - name: "Blue"
        range: "3:22-26[36-40]"
  - name: "Mood"
    range: "4:2-9:3[44-94]"
    variants:
      - name: "Unsure"
        range: "5:3-13[53-63]"
        value: 0
      - name: "Happy"
        range: "6:3-8[67-72]"
      - name: "Sad"
        range: "7:3-6[76-79]"
      - name: "Excited"
        range: "8:3-10[83-90]"
```

# block annotations

```pragma
enum Color {
	WithComma {
		p#shared_option = 1
		regular_option = false
	},
	WithoutComma = 2 {
		x#"meshapi:meta" = "something"
	}
	LastVariant = 3
}
```

```yaml
enums:
  - name: "Color"
    range: "1:6-10:2[5-151]"
    variants:
      - name: "WithComma"
        range: "2:2-5:3[14-75]"
        annotations:
          block:
            - private: true
              range: "3:5-22[30-47]"
              key_path:
                content: "shared_option"
                range: "3:5-18[30-43]"
              value:
                range: "3:21-22[46-47]"
                data: 1
            - range: "4:3-25[50-72]"
              key_path:
                content: "regular_option"
                range: "4:3-17[50-64]"
              value:
                range: "4:20-25[67-72]"
                data: false
      - name: "WithoutComma"
        range: "6:2-8:3[78-132]"
        value: 2
        annotations:
          block:
            - extra: true
              range: "7:5-33[101-129]"
              key_path:
                content: "meshapi:meta"
                range: "7:5-19[101-115]"
              value:
                range: "7:22-33[118-129]"
                data: "something"
      - name: "LastVariant"
        range: "9:2-17[134-149]"
        value: 3
```

# invalid tag

```pragma
enum Color {
	Red = -1 #ignore,
	Blue = 9999999999999999
}
```

```txt
enums:
  - name: "Color"
    range: "1:6-4:2[5-58]"
    variants:
      - name: "Red"
        range: "2:2-18[14-30]"
        annotations:
          - range: "2:12-18[24-30]"
            key_path:
              content: "ignore"
              range: "2:12-18[24-30]"
            value:
              range: "2:12-18[24-30]"
              data: true
      - name: "Blue"
        range: "3:2-25[33-56]"

2:8-10[20-22] enum value must be a positive integer from 0 to 2^32-1 @literal=-1
3:9-25[40-56] enum value must be a positive integer from 0 to 2^32-1 @literal=9999999999999999
```

# recovery

```pragma
enum Color {
	Red = -1 #ignore {
        54
    },
    whatever
	Blue = 9999999999999999,
    Green,
}

enum (
    Kind {
        User Admin ServiceAccount
    }

    AnotherOne {
        This, One, Works
    }
)
```

```txt
enums:
  - name: "Color"
    range: "1:6-8:2[5-102]"
    variants:
      - name: "Red"
        range: "2:2-4:6[14-49]"
        annotations:
          - range: "2:11-4:6[23-49]"
            key_path:
              content: "ignore"
              range: "2:12-18[24-30]"
            block:
      - name: "whatever"
        range: "5:5-6:25[55-88]"
      - name: "Green"
        range: "7:5-10[94-99]"
  - name: "Kind"
    range: "11:5-13:6[115-161]"
    variants:
      - name: "User"
        range: "12:9-13:6[130-161]"
  - name: "AnotherOne"
    range: "15:5-17:6[167-210]"
    variants:
      - name: "This"
        range: "16:9-13[188-192]"
      - name: "One"
        range: "16:15-18[194-197]"
      - name: "Works"
        range: "16:20-25[199-204]"

2:8-10[20-22] enum value must be a positive integer from 0 to 2^32-1 @literal=-1
3:9-11[41-43] expected annotation key path or string @literal=54
6:2-6[65-69] expected annotation modifier or end of statement @literal=Blue
12:14-19[135-140] expected annotation modifier or end of statement @literal=Admin
```
