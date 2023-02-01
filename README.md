# :writing_hand: A Parsing Module for Jai

A wee parsing module for the Jai programming language. You can check the code in [parse.jai](parse.jai) and [tokenizer.jai](tokenizer.jai) then a few examples of how to use them in [example.jai](example.jai).

## How To

### Parse

The idea is to go from a string (from a file or some whatever data) to a struct variable filled with the data on the file. So if we had a struct like this:
```
Settings :: struct
{
    quality : enum { LOW; MEDIUM; HIGH; };
    your_top_3_best_fruits : [3]string; // very important
    mouse_sensitivity : float;
}
```
You could have a file containing something like this:
```
quality = HIGH
your_top_3_best_fruits = ["banana", "mango", "apricot"]
mouse_sensitivity = 3.14159
```
And at runtime you can load it into a settings variable as such (ignoring error handling for brevity):
```
file := read_file("my.settings");
settings : Settings;
parse(file, *settings);
```

A really useful mix is combining this with Jai's `File_Watcher` module, which notifies you when files get changed. With a few lines you can end up with a hotloaded file with any arbitrary data for those juicy iteration times. 

### Unparse

You can also do the reverse operation going from a variable to a string. This is especially useful if you want to do something like loading a file, edit it or let the values change during the execution of your program then export that same file with the modifications. Following the example above you could do:
```
builder : String_Builder;
unparse(*builder, *settings);
write_file("my.settings", builder_to_string(*builder));
```

## License

I want people to be able to just use this without thinking about licensing, although give me a shout if you do use it and attribution is appreciated 😊. Replicating STB's (https://github.com/nothings/stb) licensing stuff where you can choose to use public domain or MIT.
