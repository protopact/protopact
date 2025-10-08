# empty interface

```pactum
interface UserService {
}
```

```yaml
options:
interfaces:
  - name: "UserService"
    range: "1:11[10-25]"
    options:
    funcs:
```

# interface with functions and no param

```pactum
interface UserService {
	s#openapi.tags = ["tag one" "tag two"]

	FuncWithoutParamWithSemicolon();
	FuncWithoutParamWithOptionsSemicolon() s#api.deprecated;
	FuncWithoutParamWithOptionsBlock() {}
	FuncWithoutParamWithOptionsBlockAndSemicolon() {};
}
```

```yaml
options:
interfaces:
  - name: "UserService"
    range: "1:11[10-249]"
    options:
      - raw: false
        shared: true
        range: "2:4[27-63]"
        selector:
          content: "openapi.tags"
          range: "2:4[27-39]"
        value:
          range: "2:19[42-63]"
          data:
            - range: "2:20[43-52]"
              data: "tag one"
            - range: "2:30[53-62]"
              data: "tag two"
    funcs:
      - name: "FuncWithoutParamWithSemicolon"
        range: "4:2[66-98]"
        tag: null
        input: null
        output: null
        options:
      - name: "FuncWithoutParamWithOptionsSemicolon"
        range: "5:2[100-156]"
        tag: null
        input: null
        output: null
        options:
          - raw: false
            shared: true
            range: "5:43[141-155]"
            selector:
              content: "api.deprecated"
              range: "5:43[141-155]"
            value:
              range: "5:43[141-155]"
              data: true
      - name: "FuncWithoutParamWithOptionsBlock"
        range: "6:2[158-195]"
        tag: null
        input: null
        output: null
        options:
      - name: "FuncWithoutParamWithOptionsBlockAndSemicolon"
        range: "7:2[197-247]"
        tag: null
        input: null
        output: null
        options:
```

# interface with args and tags

```pactum
interface UserService {
	FuncWithInput(some_pact.Input) = 1;
	FuncWithStreamingInputEmptyOutput(stream some_pact.Input) -> () = 2 s#api.deprecated;
	FuncWithOutputArgs(stream some_pact.Input) -> some_pact.Output = 3 {};
	FuncWithStreamingArgs(stream some_pact.Input) -> stream some_pact.Output = 4 {}
}
```

```yaml
options:
interfaces:
  - name: "UserService"
    range: "1:11[10-302]"
    options:
    funcs:
      - name: "FuncWithInput"
        range: "2:2[25-60]"
        tag: 1
        input:
          name:
            content: "some_pact.Input"
            range: "2:16[39-54]"
          streaming: false
        output: null
        options:
      - name: "FuncWithStreamingInputEmptyOutput"
        range: "3:2[62-147]"
        tag: 2
        input:
          name:
            content: "some_pact.Input"
            range: "3:43[103-118]"
          streaming: true
        output: null
        options:
          - raw: false
            shared: true
            range: "3:72[132-146]"
            selector:
              content: "api.deprecated"
              range: "3:72[132-146]"
            value:
              range: "3:72[132-146]"
              data: true
      - name: "FuncWithOutputArgs"
        range: "4:2[149-219]"
        tag: 3
        input:
          name:
            content: "some_pact.Input"
            range: "4:28[175-190]"
          streaming: true
        output:
          name:
            content: "some_pact.Output"
            range: "4:48[195-211]"
          streaming: false
        options:
      - name: "FuncWithStreamingArgs"
        range: "5:2[221-300]"
        tag: 4
        input:
          name:
            content: "some_pact.Input"
            range: "5:31[250-265]"
          streaming: true
        output:
          name:
            content: "some_pact.Output"
            range: "5:58[277-293]"
          streaming: true
        options:
```
