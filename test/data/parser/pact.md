# simple pact

```pactum
pact a.b.c
```

```yaml
pact:
  content: "a.b.c"
  range: "1:6[5-10]"
  segments:
    - content: "a"
      position: "1:6"
    - content: "b"
      position: "1:8"
    - content: "c"
      position: "1:10"
```

# longer pact

```pactum
pact meshapi.gateway.v1
```

```yaml
pact:
  content: "meshapi.gateway.v1"
  range: "1:6[5-23]"
  segments:
    - content: "meshapi"
      position: "1:6"
    - content: "gateway"
      position: "1:14"
    - content: "v1"
      position: "1:22"
```

# single pact

```pactum
pact meshapi
```

```yaml
pact:
  content: "meshapi"
  range: "1:6[5-12]"
  segments:
    - content: "meshapi"
      position: "1:6"
```

# invalid extra dot

```pactum
pact meshapi.gateway.v1.
```

```yaml
0:0[0] unexpected end of file @literal=
```

# extra identifier

```pactum
pact meshapi.gateway.v1 additional
```

```yaml
1:25[24-34] unexpected token @literal=additional
```

# too many dots

```pactum
pact meshapi.gateway..
```

```yaml
1:22[21-22] unexpected token @literal=.
```

# no pact

```pactum
pact
```

```yaml
0:0[0] unexpected end of file @literal=
```

# duplicated pact

```pactum
pact a.b.c
pact meshapi.gateway
```

```yaml
2:6[16-31] duplicated pact statement, each document can have a single pact statement @literal=meshapi.gateway
```
