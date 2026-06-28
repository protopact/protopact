# single quote

```pragma
import 'some/package'
```

```yaml
imports:
  - path: "some/package"
    range: "1:8-22[7-21]"
```

# double quote

```pragma
import "some/package"
```

```yaml
imports:
  - path: "some/package"
    range: "1:8-22[7-21]"
```

# wildcard

```pragma
import # "some/package"
```

```yaml
imports:
  - bare: true
    path: "some/package"
    range: "1:8-24[7-23]"
```

# alias

```pragma
import name "some/package"
```

```yaml
imports:
  - alias: "name"
    path: "some/package"
    range: "1:8-27[7-26]"
```

# import group / all flavors

```pragma
import (
  #w "wildcard"
  alias "some/package"
	"regular"
)
```

```yaml
imports:
  - alias: "w"
    bare: true
    path: "wildcard"
    range: "2:3-16[11-24]"
  - alias: "alias"
    path: "some/package"
    range: "3:3-23[27-47]"
  - path: "regular"
    range: "4:2-11[49-58]"
```

# import number (error)

```pragma
import 1.23
```

```yaml
1:8-12[7-11] expected path string @literal=1.23
```

# import with alias and no package (error)

```pragma
import alias
```

```yaml
0:0[0] unexpected end of file
```
