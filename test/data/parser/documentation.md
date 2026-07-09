# documentation

```pragma
//! this is a documentation
```

```yaml
documentation: |
  this is a documentation
```

# multi-line documentation

```pragma
//! this is a documentation
// with comment in between
//! more documentation
/* a different style of documentation */
```

```yaml
documentation: |
  this is a documentation
  more documentation
```

# misplaced package documentation

```pragma
struct A {}

//! Whatever
```

```yaml
2:0[13] unexpected package documentation
```

# struct documentation

```pragma
//! this is a documentation for the package

// ignore the comments
/// This is a documentation for the struct!
struct SomeMessage {
	/// This is a documentation for the field.
	// there can be comments as well.
    some_field: string = 1 #optional
}
```

```yaml
documentation: |
  this is a documentation for the package
structs:
  - name: "SomeMessage"
    documentation: |
      This is a documentation for the struct!
    members:
      - name: "some_field"
        documentation: |
          This is a documentation for the field.
        type: "string"
        tag: 1
```

# struct group with prior documentation

```pragma
// comments

/// Documentation!
struct (
    Something {}
)
```

```yaml
2:0[13] unused documentation, use plain comments instead
```

# struct group

```pragma
//! this is a documentation for the package

struct (
    // ignore the comments
	/// This is a documentation for the struct!
    SomeMessage {
        /// This is a documentation for the field.
        // there can be comments as well.
        some_field: string = 1 #optional
    }

    /// Another documentation, many miles away.
    /// it is multi-line
    /// as well.

	AnotherOne {
	}
)
```

```yaml
documentation: |
  this is a documentation for the package
structs:
  - name: "SomeMessage"
    documentation: |
      This is a documentation for the struct!
    members:
      - name: "some_field"
        documentation: |
          This is a documentation for the field.
        type: "string"
        tag: 1
  - name: "AnotherOne"
    documentation: |
      Another documentation, many miles away.
      it is multi-line
      as well.
```

# protocol documentation

```pragma
//! this is a documentation for the package

// ignore the comments
/// This is a documentation for the protocol!
protocol SomeService {
	/// This is a documentation for the func.
	// there can be comments as well.
  SomeFunc();
}
```

```yaml
documentation: |
  this is a documentation for the package
protocols:
  - name: "SomeService"
    documentation: |
      This is a documentation for the protocol!
    funcs:
      - name: "SomeFunc"
        documentation: |
          This is a documentation for the func.
```

# protocol group

```pragma
//! this is a documentation for the package

protocol (
  // ignore the comments
  /// This is a documentation for the protocol!
  SomeService {
    /// This is a documentation for the func.
    // there can be comments as well.
    SomeFunc();
  }
)
```

```yaml
documentation: |
  this is a documentation for the package
protocols:
  - name: "SomeService"
    documentation: |
      This is a documentation for the protocol!
    funcs:
      - name: "SomeFunc"
        documentation: |
          This is a documentation for the func.
```

# enum documentation

```pragma
//! this is a documentation for the package

// ignore the comments
/// This is a documentation for the enum!
enum Color {
	// ignore comment.
	/// We all know red.
	Red,
	/* TODO: write a better description for this. */
    /// Well, you know, color of the trees, eh?
    /// Or maybe, grass? definitely not mountains.
	Green,
	/// Documentation for blue.
	// even though there are comments here, the documentation
	// gets parsed properly.
	Blue,
}
```

```yaml
documentation: |
  this is a documentation for the package
enums:
  - name: "Color"
    documentation: |
      This is a documentation for the enum!
    variants:
      - name: "Red"
        documentation: |
          We all know red.
      - name: "Green"
        documentation: |
          Well, you know, color of the trees, eh?
          Or maybe, grass? definitely not mountains.
      - name: "Blue"
        documentation: |
          Documentation for blue.
```

# const documentation

```pragma
//! this is a documentation for the package

// ignore
/// Name is pretty obvious!
/* this is a comment and should NOT
 * be part of the documentation!
 */
const Name = "#pragma once"

const (
    /// Another is in a group
    Another = 1

	// ignore
	/// Documentation
	YetAnother = "Something"

	/// Documentation for the last one
	// ignore
	LastOne = { "tags": [1.2] }
)
```

```yaml
documentation: |
  this is a documentation for the package
constants:
  - name: "Name"
    documentation: |
      Name is pretty obvious!
    value: "#pragma once"
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
      - key: "tags"
        value:
          - 1.2
```
