# pact documentation

```pactum
/// this is a documentation
```

```yaml
documentation: |
  this is a documentation
```

# multi-line documentation

```pactum
/// this is a documentation
// with comment in between
/// more documentation
/** a different style of documentation */
/**
 * multiple-lines
 */
```

```yaml
documentation: |
  this is a documentation
  more documentation
  a different style of documentation 
  * multiple-lines
```

# message documentation

```pactum
/// this is a documentation for the pact
pact something

// ignore the comments
/// This is a documentation for the message!
message SomeMessage {
	/// This is a documentation for the field.
	// there can be comments as well.
  some_field: string = 1 #optional
}
```

```yaml
documentation: |
  this is a documentation for the pact
messages:
  - name: "SomeMessage"
    documentation: |
      This is a documentation for the message!
    fields:
      - name: "some_field"
        documentation: |
          This is a documentation for the field.
        type: "string"
        tag: 1
        nullable: false
        options:
```

# message group

```pactum
/// this is a documentation for the pact
pact something

message (
	// ignore the comments
	/// This is a documentation for the message!
  SomeMessage {
		/// This is a documentation for the field.
		// there can be comments as well.
		some_field: string = 1 #optional
	}

	/** Another documentation.
	*/
	AnotherOne {
	}
)
```

```yaml
documentation: |
  this is a documentation for the pact
messages:
  - name: "SomeMessage"
    documentation: |
      This is a documentation for the message!
    fields:
      - name: "some_field"
        documentation: |
          This is a documentation for the field.
        type: "string"
        tag: 1
        nullable: false
        options:
  - name: "AnotherOne"
    documentation: |
      Another documentation.
```

# interface documentation

```pactum
/// this is a documentation for the pact
pact something

// ignore the comments
/// This is a documentation for the interface!
interface SomeService {
	/// This is a documentation for the func.
	// there can be comments as well.
  SomeFunc();
}
```

```yaml
documentation: |
  this is a documentation for the pact
interfaces:
  - name: "SomeService"
    documentation: |
      This is a documentation for the interface!
    funcs:
      - name: "SomeFunc"
        documentation: |
          This is a documentation for the func.
```

# interface group

```pactum
/// this is a documentation for the pact
pact something

interface (
  // ignore the comments
  /// This is a documentation for the interface!
  SomeService {
	  /// This is a documentation for the func.
	  // there can be comments as well.
    SomeFunc();
  }
)
```

```yaml
documentation: |
  this is a documentation for the pact
interfaces:
  - name: "SomeService"
    documentation: |
      This is a documentation for the interface!
    funcs:
      - name: "SomeFunc"
        documentation: |
          This is a documentation for the func.
```

# enum documentation

```pactum
/// this is a documentation for the pact
pact something

// ignore the comments
/// This is a documentation for the interface!
enum Color {
	// ignore comment.
	/// We all know red.
	Red,
	/** Not sure about this one though.*/
	Green,
	/// Documentation for blue.
	// even though there are comments here, the documentation
	// gets parsed properly.
	Blue,
}
```

```yaml
documentation: |
  this is a documentation for the pact
enums:
  - name: "Color"
    documentation: |
      This is a documentation for the interface!
    variants:
      - name: "Red"
        documentation: |
          We all know red.
      - name: "Green"
        documentation: |
          Not sure about this one though.
      - name: "Blue"
        documentation: |
          Documentation for blue.
```

# const documentation

```pactum
/// this is a documentation for the pact
pact something

// ignore
/// Name is pretty obvious!
/* this is a comment and should NOT
 * be part of the documentation!
 */
const Name = "Pactum"

const (
	/// Another is in a group
  Another = 1

	// ignore
	/// Documentation
	YetAnother = "Something"

	/// Documentation for the last one
	// ignore
	LastOne = { "tags" = [1.2] }
)
```

```yaml
documentation: |
  this is a documentation for the pact
constants:
  - name: "Name"
    value: "Pactum"
  - name: "Another"
    documentation: |
      Another is in a group
    value: 1
  - name: "YetAnother"
    documentation: |
      Documentation
    value: "Something"
  - name: "LastOne"
    documentation: |
      Documentation for the last one
    value:
      key: "tags"
      value:
        - 1.2
```
