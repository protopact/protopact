# empty protocol

```pragma
protocol UserService {
}
```

```yaml
protocols:
  - name: "UserService"
    range: "1:10-2:2[9-24]"
```

# protocol with functions and no param

```pragma
protocol UserService {
	p#openapi.tags = ["tag one" "tag two"]

	FuncWithoutParamWithSemicolon();
	FuncWithoutParamWithOptionsSemicolon() p#api.deprecated;
	FuncWithoutParamWithOptionsBlock() {}
	FuncWithoutParamWithOptionsBlockAndSemicolon() {};
}
```

```yaml
protocols:
  - name: "UserService"
    range: "1:10-8:2[9-248]"
    annotations:
      - private: true
        range: "2:4-40[26-62]"
        key_path:
          content: "openapi.tags"
          range: "2:4-16[26-38]"
        value:
          range: "2:19-40[41-62]"
          data:
            - range: "2:20-29[42-51]"
              data: "tag one"
            - range: "2:30-39[52-61]"
              data: "tag two"
    funcs:
      - name: "FuncWithoutParamWithSemicolon"
        range: "4:2-33[65-96]"
      - name: "FuncWithoutParamWithOptionsSemicolon"
        range: "5:2-57[99-154]"
        annotations:
          - private: true
            range: "5:43-57[140-154]"
            key_path:
              content: "api.deprecated"
              range: "5:43-57[140-154]"
            value:
              range: "5:43-57[140-154]"
              data: true
      - name: "FuncWithoutParamWithOptionsBlock"
        range: "6:2-39[157-194]"
      - name: "FuncWithoutParamWithOptionsBlockAndSemicolon"
        range: "7:2-51[196-245]"
```

# protocol with args and tags

```pragma
protocol UserService {
	FuncWithInput(some_pact.Input) = 1;
	FuncWithStreamingInputEmptyOutput(stream some_pact.Input) -> () = 2 p#api.deprecated;
	FuncWithOutputArgs(stream some_pact.Input) -> some_pact.Output = 3 {};
	FuncWithStreamingArgs(stream some_pact.Input) -> stream some_pact.Output = 4 {}
}
```

```yaml
protocols:
  - name: "UserService"
    range: "1:10-6:2[9-301]"
    funcs:
      - name: "FuncWithInput"
        range: "2:2-36[24-58]"
        tag: 1
        input:
          name:
            content: "some_pact.Input"
            range: "2:16-31[38-53]"
          streaming: false
      - name: "FuncWithStreamingInputEmptyOutput"
        range: "3:2-86[61-145]"
        tag: 2
        input:
          name:
            content: "some_pact.Input"
            range: "3:43-58[102-117]"
          streaming: true
        annotations:
          - private: true
            range: "3:72-86[131-145]"
            key_path:
              content: "api.deprecated"
              range: "3:72-86[131-145]"
            value:
              range: "3:72-86[131-145]"
              data: true
      - name: "FuncWithOutputArgs"
        range: "4:2-71[148-217]"
        tag: 3
        input:
          name:
            content: "some_pact.Input"
            range: "4:28-43[174-189]"
          streaming: true
        output:
          name:
            content: "some_pact.Output"
            range: "4:48-64[194-210]"
          streaming: false
      - name: "FuncWithStreamingArgs"
        range: "5:2-81[220-299]"
        tag: 4
        input:
          name:
            content: "some_pact.Input"
            range: "5:31-46[249-264]"
          streaming: true
        output:
          name:
            content: "some_pact.Output"
            range: "5:58-74[276-292]"
          streaming: true
```
