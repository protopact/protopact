# single quote

```pactum
import 'some/package'
```

```yaml
imports:
  - alias: ""
    implicit: false
    path: "some/package"
    range: "1:8[7-21]"
```

# double quote

```pactum
import "some/package"
```

```yaml
imports:
  - alias: ""
    implicit: false
    path: "some/package"
    range: "1:8[7-21]"
```

# wildcard

```pactum
import _ "some/package"
```

```yaml
imports:
  - alias: ""
    implicit: true
    path: "some/package"
    range: "1:8[7-23]"
```

# wildcard

```pactum
import name "some/package"
```

```yaml
imports:
  - alias: "name"
    implicit: false
    path: "some/package"
    range: "1:8[7-26]"
```

# import group / all flavors

```pactum
import (
  _ "wildcard"
  alias "some/package"
	"regular"
)
```

```yaml
imports:
  - alias: ""
    implicit: true
    path: "wildcard"
    range: "2:3[11-23]"
  - alias: "alias"
    implicit: false
    path: "some/package"
    range: "3:3[26-46]"
  - alias: ""
    implicit: false
    path: "regular"
    range: "4:2[48-57]"
```

# import number (error)

```pactum
import 1.23
```

```yaml
1:8[7] expected path string @literal=1.23
```

# import with alias and no package (error)

```pactum
import alias
```

```yaml
0:0[0] unexpected end of file @literal=
```
