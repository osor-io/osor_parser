//
// This is a parser to go from string to an arbitrary instance of a given struct.
//
// There's an example in example.jai where we test some of the features which are:
//
// - Parsing all basic types and copying the values directly into the struct.
// - Parsing arrays, that being fixed, dynamic or views. Allocating only for dynamic and views.
// - Parsing enums, it can find the name, match it to the value and write it to the result.
// - Parsing strings, either pointing to the provided string or copying the string.
// - Parsing pointers, allocating the needed type and filling it. There's a custom pointer_allocator
//   that can be provided, so the memory for a given type is provided by the user.
// - Parsing nested structs and handling 'using' correctly. This means that at the base struct level
//   you can put the name of a member living on a child struct that is marked with 'using'
// - Option to specify how many elements are on an array to only allocate once 'array = 3 [1,2,3]'
//
//
// Considerations:
//
// - Currently if you parse the same member multiple times it'll overwrite it with the last one,
//   which means that if you put something like a string or an array twice you might be leaking that memory.
//
// - If we fail to parse for some reason and throw an error, this will NOT clean up the struct and the
//   members that it already allocated. So in an error case you might be leaking memory as well. 
//
// - During the tokenization process this will allocate memory for the tokens that is freed when returning
//   from the procedure always thanks to defer. So that will never leak, but is a consideration to have, 
//   especially if you're providing a custom allocator in the context.
//
//
// Other possible improvements
//
// - We could give the option to provide an instance of a struct that only patch the members that are found
//   on the file. If there are pointers or arrays, it would reuse the memory from those (reallocating the arrays
//   if necessary). This is not useful however if you are removing fields from a file you already loaded cause
//   it would leave them there as they were (not default initializing them again). But this might have its uses.
//
//



Parse_Settings :: struct
{
    copy_strings := false; 
    // If false, the strings on the result will just be slice of the provided input string

    allow_allocations := false;
    // If you disallow them there's things that can't be done such as arrays, 
    // pointers (if you don't provide a pointer_allocator) or copy strings

    pointer_allocator : (info : *Type_Info, allocator_data : *void) -> *void;
    pointer_allocator_data : *void;
    // This allows you to provide memory for a pointer of the given type

    //
    // @@NOTE: Arrays are allocated with alloc/realloc which will use whatever allocator is in the context.
    //
}
PARSE_SETTINGS_WITH_ALLOCATIONS :: Parse_Settings.
{
    copy_strings = true,
    allow_allocations = true,
};



parse :: (the_string : string, result : *$Result_Type, settings := Parse_Settings.{}, $custom_struct_parsing := () -> bool #expand { return false; }) -> success : bool, error : string
{
    parse_one :: (token : *Token, info : *Type_Info, value_pointer : *void, settings : Parse_Settings, is_first_call := false) -> *Token #must, success : bool #must, error : string #must
    {
        error :: (token : *Token, format : string, arguments : .. Any) -> string
        {
            user_message := tprint(format, ..arguments);
            complete_message := tprint("%\n    line %: %\n", user_message, token.line.number, token.line.text);
            return complete_message;
        } @PrintLike

        if #complete info.type == 
        {
            case .INTEGER;
            info_int := cast(*Type_Info_Integer) info;
            negate := false;
            if token.type == .Plus  
            {
                token += 1;
            }
            else if token.type == .Minus 
            {
                negate = true;
                token += 1;
            }
            if token.type != .Integer
            {
                return null, false, error(token, "Expected Integer but found %", token.type);
            }
            value, integer_parse_success, integer_parse_error := token_to_integer(token);
            if !integer_parse_success then return null, false, error(token, "Couldn't parse integer number: %\n", integer_parse_error);
            if info_int.signed  
            {
                signed_value := cast(s64)value;
                if negate then signed_value = -signed_value;
                if      info.runtime_size == 1 { v := cast,trunc(s8)  signed_value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else if info.runtime_size == 2 { v := cast,trunc(s16) signed_value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else if info.runtime_size == 4 { v := cast,trunc(s32) signed_value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else if info.runtime_size == 8 { v := cast,trunc(s64) signed_value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else assert(false);
            }
            else
            {
                if negate then return null, false, error(token, "Setting negative value (%) on unsigned member", value);
                if      info.runtime_size == 1 { v := cast,trunc(u8)  value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else if info.runtime_size == 2 { v := cast,trunc(u16) value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else if info.runtime_size == 4 { v := cast,trunc(u32) value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else if info.runtime_size == 8 { v := cast,trunc(u64) value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else assert(false);
            }
            token += 1;



            case .FLOAT;
            negate := false;
            if token.type == .Plus  
            {
                token += 1;
            }
            else if token.type == .Minus 
            {
                negate = true;
                token += 1;
            }
            if !(token.type == .Float || token.type == .Integer)
            {
                return null, false, error(token, "Expected Integer or Float but found %", token.type);
            }
            value_f64, success, remainder := string_to_float64(token.text);
            assert(success);
            assert(remainder.count == 0);
            if negate then value_f64 = -value_f64;
            token += 1;
            if token.type == .Hash
            {
                token += 1;
                if token.type == .Integer
                {
                    value_u64, integer_parse_success, integer_parse_error := token_to_integer(token);
                    if !integer_parse_success then return null, false, error(token, "Couldn't parse integer number: %\n", integer_parse_error);
                    value_u64_as_f64 := (cast(*float64)(*value_u64)).*;
                    diff := value_f64 - value_u64_as_f64;
                    if diff < 0 then diff = -diff;
                    value_f64_positive := ifx value_f64 < 0 then -value_f64 else value_f64;
                    THRESHOLD_BASED_ON_F32_PRECISSION :: 0.000001;
                    if (diff / value_f64_positive) > THRESHOLD_BASED_ON_F32_PRECISSION 
                    {
                        return null, false, error(token, "The floating point value embedded as bytes (after #) differs too much from the actual number written (difference was %), if you edited the file you should delete the # and the integer after", diff);
                    }
                    else
                    {
                        value_f64 = value_u64_as_f64;
                    }
                    token += 1;
                }
                else
                {
                    return null, false, error(token, "Expected Integer as the int representation of a float (after a #) but found %", token.type);
                }
            }
            if info.runtime_size == 8
            {
                assert(info.runtime_size == size_of(type_of(value_f64)));
                memcpy(value_pointer, *value_f64, size_of(type_of(value_f64)));
            }
            else if info.runtime_size == 4
            {
                value_32 := cast(float32) value_f64;
                assert(info.runtime_size == size_of(type_of(value_32)));
                memcpy(value_pointer, *value_32, size_of(type_of(value_32)));
            }
            else assert(false);



            case .BOOL;
            if token.type != .Bool
            {
                return null, false, error(token, "Expected Bool but found %", token.type);
            }
            value := false;
            if      compare_nocase(token.text, "true") == 0
                value = true;
            else if compare_nocase(token.text, "false") == 0
                value = false;
            else assert(false);
            assert(info.runtime_size == size_of(type_of(value)));
            memcpy(value_pointer, *value, size_of(type_of(value)));
            token += 1;



            case .STRING;
            the_string : string;
            if token.type != .String
            {
                return null, false, error(token, "Expected String but found %", token.type);
            }
            if settings.copy_strings
            {
                if !settings.allow_allocations
                {
                    return null, false, error(token, "Requested to copy a string but settings dissallow allocations");
                }
                the_string = copy_string(token.text);
            }
            else
                the_string = token.text;
            assert(info.runtime_size == size_of(type_of(the_string)));
            memcpy(value_pointer, *the_string, size_of(type_of(the_string)));
            token += 1;



            case .ENUM;
            enum_info := cast(*Type_Info_Enum) info;
            value : type_of(enum_info.values[0]);
            first_enum_token := token;
            while true
            {
                if token.type == .Identifier
                {
                    enum_index := -1;
                    for enum_info.names  
                        if it == token.text  
                            enum_index = it_index;
                    if enum_index < 0
                    {
                        return null, false, error(token, "Enum value % didn't match any of the possible values for %", token.text, enum_info.name);
                    }
                    value |= enum_info.values[enum_index];
                }
                else if token.type == .String
                {
                    if token.text.count != 1
                    {
                        return null, false, error(token, "Enum value passed as string % must be a single character", token.text);
                    }
                    value |= xx token.text[0];
                }
                else if token.type == .Integer
                {
                    int_value, integer_parse_success, integer_parse_error := token_to_integer(token);
                    if !integer_parse_success then return null, false, error(token, "Couldn't parse integer number: %\n", integer_parse_error);
                    value |= xx int_value;
                }
                else
                {
                    return null, false, error(token, "Expected Identifier but found %", token.type);
                }
                token += 1;
                if (enum_info.enum_type_flags & .FLAGS) && token.type == .Vertical_Slash
                {
                    token += 1;
                }
                else
                {
                    break;
                }
            }
            signed := enum_info.internal_type.signed;
            if signed
            {
                if      info.runtime_size == 1 { v := cast,trunc(s8)  value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else if info.runtime_size == 2 { v := cast,trunc(s16) value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else if info.runtime_size == 4 { v := cast,trunc(s32) value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else if info.runtime_size == 8 { v := cast,trunc(s64) value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else assert(false);
            }
            else
            {
                if value < 0  
                {
                    return null, false, error(first_enum_token, "Setting negative value (%) on unsigned member", value);
                }
                if      info.runtime_size == 1 { v := cast,trunc(u8)  value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else if info.runtime_size == 2 { v := cast,trunc(u16) value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else if info.runtime_size == 4 { v := cast,trunc(u32) value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else if info.runtime_size == 8 { v := cast,trunc(u64) value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else assert(false);
            }



            case .POINTER;
            pointer_info := cast(*Type_Info_Pointer) info;
            pointer_to_fill : *void;
            if settings.pointer_allocator
                pointer_to_fill = settings.pointer_allocator(pointer_info.pointer_to, settings.pointer_allocator_data);
            if pointer_to_fill == null && settings.allow_allocations
                pointer_to_fill = alloc(pointer_info.pointer_to.runtime_size);
            if pointer_to_fill == null
                return null, false, error(token, "Found a pointer type to fill but we couldn't allocate memory for it");
            assert(pointer_to_fill != null);
            if pointer_info.pointer_to.type == .STRUCT
            {
                struct_info := cast(*Type_Info_Struct) pointer_info.pointer_to;
                if struct_info.initializer
                    struct_info.initializer(pointer_to_fill);
            }
            successful_parse : bool;
            pointer_parse_error : string;
            token, successful_parse, pointer_parse_error = parse_one(token, pointer_info.pointer_to, pointer_to_fill, settings);
            if !successful_parse then return token, false, pointer_parse_error;
            assert(info.runtime_size == size_of(type_of(pointer_to_fill)));
            memcpy(value_pointer, *pointer_to_fill, size_of(type_of(pointer_to_fill)));



            case .ARRAY;
            array_info := cast(*Type_Info_Array) info;
            array_type := array_info.element_type;
            is_struct := array_type.type == .STRUCT;

            indicated_size_on_file := -1;
            if token.type == .Integer
            {
                value, integer_parse_success, integer_parse_error := token_to_integer(token);
                if !integer_parse_success then return null, false, error(token, "Couldn't parse integer number: %\n", integer_parse_error);
                if value < 0
                    return null, false, error(token, "Requested array to have negative size '%', ignoring", value);
                else
                    indicated_size_on_file = cast(s64)value;
                token += 1;
            }
            if token.type != .Open_Brackets
            {
                return null, false, error(token, "Expected Opening Bracket '[' but found %", token.type);
            }
            token += 1;

            static_size : *int;
            if #complete array_info.array_type ==
            {
                case .FIXED;
                static_size = *array_info.array_count;
                if indicated_size_on_file != -1 && static_size.* != indicated_size_on_file
                {
                    return null, false, error(token, "Indicated size on file (%) is different than the size of the fixed array (%)", indicated_size_on_file, static_size.*);
                }

                case .VIEW; #through;
                case .RESIZABLE;
                assert(array_info.array_count == -1, "Unexpected array count");
            }

            if static_size == null && !settings.allow_allocations
            {
                return null, false, error(token, "Found dynamic array but allocations are disallowed by parse settings");
            }

            array_data : Resizable_Array; 
            array_data.allocator = context.allocator;
            if static_size
            {
                array_data.data = value_pointer;
                array_data.allocated = static_size.*;
            }
            else if indicated_size_on_file != -1
            {
                array_data.allocated = indicated_size_on_file;
                assert(settings.allow_allocations);
                array_data.data = alloc(array_data.allocated * array_type.runtime_size, array_data.allocator);
                struct_info := cast(*Type_Info_Struct) array_type;
                if is_struct && struct_info.initializer
                    for index : 0..array_data.allocated-1
                        struct_info.initializer(array_data.data + (index * array_type.runtime_size));
                else
                    memset(array_data.data, 0, array_data.allocated * array_type.runtime_size);
            }
            while true
            {
                if token.type == .Close_Brackets break;

                if array_data.count >= array_data.allocated
                {
                    if static_size
                    {
                        return null, false, error(token, "Trying to add too many elements to static array of size %\n", static_size.*);
                    }
                    else if indicated_size_on_file != -1
                    {
                        return null, false, error(token, "Indicated size on file was '%' but more elements are present on the file", indicated_size_on_file);
                    }

                    old_allocated := array_data.allocated;
                    array_data.allocated = max(8, array_data.allocated * 2);
                    assert(settings.allow_allocations);
                    array_data.data = realloc(array_data.data, 
                                              array_data.allocated * array_type.runtime_size, 
                                              old_allocated * array_type.runtime_size,
                                              array_data.allocator); 
                    struct_info := cast(*Type_Info_Struct) array_type;
                    if is_struct && struct_info.initializer
                        for index : old_allocated..array_data.allocated-1
                            struct_info.initializer(array_data.data + (index * array_type.runtime_size));
                    else
                        memset(array_data.data + (old_allocated * array_type.runtime_size), 0, (array_data.allocated - old_allocated) * array_type.runtime_size);
                }

                pointer_to_current := array_data.data + (array_data.count * array_type.runtime_size);
                successful_parse : bool;
                array_element_parse_error : string;
                token, successful_parse, array_element_parse_error = parse_one(token, array_type, pointer_to_current, settings);
                if !successful_parse then return token, false, array_element_parse_error;
                array_data.count += 1;
                if token.type == .Comma  token += 1;
            }
            if indicated_size_on_file != -1 && array_data.count != indicated_size_on_file
            {
                return null, false, error(token, "Indicated size on file was '%' but only '%' elements present on the file", indicated_size_on_file, array_data.count);
            }
            if #complete array_info.array_type ==
            {
                case .FIXED;
                assert(static_size != null);
                if array_data.count != static_size.*
                {
                    return null, false, error(token, "Not enough elements provided (%) for array of static size %", array_data.count, static_size.*);
                }
                size := array_data.count * array_type.runtime_size;
                assert(info.runtime_size == size);
                memcpy(value_pointer, array_data.data, size);

                case .VIEW;
                array_view : Array_View_64;
                array_view.count = array_data.count;
                array_view.data = array_data.data;
                assert(info.runtime_size == size_of(type_of(array_view)));
                memcpy(value_pointer, *array_view, size_of(type_of(array_view)));

                case .RESIZABLE;
                assert(info.runtime_size == size_of(type_of(array_data)));
                memcpy(value_pointer, *array_data, size_of(type_of(array_data)));
            }
            token += 1;



            case .STRUCT;
            struct_info := cast(*Type_Info_Struct) info;
            handled_by_custom_parsing := custom_struct_parsing();
            if !handled_by_custom_parsing
            {
                if !is_first_call 
                {
                    if token.type != .Open_Braces
                    {
                        return null, false, error(token, "Expected Opening Brace '{' but found %", token.type);
                    }
                    token += 1;
                }
                while true
                {
                    if !is_first_call
                    {
                        if token.type == .Close_Braces
                        {
                            token += 1;
                            break;
                        }
                    }
                    else
                    {
                        if token.type == .End  break;
                    }

                    if token.type != .Identifier
                    {
                        return null, false, error(token, "Expected identifier but found % instead", token.type);
                    } 
                    member_name := token.text;
                    token += 1;
                    if token.type != .Equals
                    {
                        return null, false, error(token, "Expected equals but found % instead", token.type);
                    }
                    token += 1;
                    
                    find_member :: (name : string, struct_info : *Type_Info_Struct) -> *Type_Info, total_offset : int
                    {
                        for * struct_info.members
                        {
                            if it.flags & .CONSTANT  
                                continue;
                            else if name == it.name
                                return it.type, it.offset_in_bytes;
                            else if it.flags & .USING && it.type.type == .STRUCT
                            {
                                type, offset := find_member(name, cast(*Type_Info_Struct) it.type);
                                if type then return type, (offset + it.offset_in_bytes);
                            }
                            //
                            // @@NOTE: This won't chase 'using' pointers.
                            //
                        }
                        return null, 0;
                    }

                    contained_type, offset_in_bytes := find_member(member_name, struct_info);
                    if !contained_type
                    {
                        return null, false, error(token, "Didn't find member '%' in struct '%' to fill in", member_name, struct_info.name);
                    }
                    member_pointer := value_pointer;
                    member_pointer += offset_in_bytes;
                    successful_parse : bool;
                    member_parse_error : string;
                    token, successful_parse, member_parse_error = parse_one(token, contained_type, member_pointer, settings);
                    if !successful_parse then return token, false, member_parse_error;
                }
            }



            case .VARIANT;
            variant_info := cast(*Type_Info_Variant)info;
            successful_parse : bool;
            variant_parse_error : string;
            token, successful_parse, variant_parse_error = parse_one(token, variant_info.variant_of, value_pointer, settings, is_first_call);
            if !successful_parse then return token, false, variant_parse_error;



            case .PROCEDURE;            #through;
            case .VOID;                 #through;
            case .OVERLOAD_SET;         #through;
            case .ANY;                  #through;
            case .POLYMORPHIC_VARIABLE; #through;
            case .TYPE;                 #through;
            case .CODE;
            return null, false, error(token, "Requesting parsing of unsupported type '%'", info.type);
        }
        return token, true, "";
    }

    tokenizer : Tokenizer;
    init_tokenizer(*tokenizer, the_string);
    tokens, tokenize_success, tokenize_error := tokenize_all_tokens(*tokenizer);
    if !tokenize_success then return false, tokenize_error;
    defer array_reset(*tokens);

    info := type_info(Result_Type);
    if info.type != .STRUCT then return false, tprint("Expected the provided type (%) to be a struct and it was % instead", info.name, info.type);

    token := tokens.data;
    while token && token.type != .End
    {
        successful_parse : bool;
        parse_error : string;
        token, successful_parse, parse_error = parse_one(token, info, result, settings, is_first_call = true);
        if !successful_parse then return false, parse_error;
    }

    return true, "";
}



unparse :: (builder : *String_Builder, data : *$Data_Type, $custom_struct_unparsing := () -> bool #expand { return false; }) -> success : bool, error : string
{
    unparse_one :: (builder : *String_Builder, info : *Type_Info, value_pointer : *void, depth : int, brackets_on_struct := true) -> success : bool #must, error : string #must
    {
        append_indentation :: (builder : *String_Builder, depth : int)
        {
            for 0..depth-1 append(builder, "    ");
        }

        if #complete info.type == 
        {
            case .INTEGER;
            format : FormatInt;
            format.value.type = info;
            format.value.value_pointer = value_pointer;
            print_integer(builder, format);



            case .FLOAT;
            float_value_as_f64 : float64;
            if      info.runtime_size == 4 { float_value_as_f64 = cast(float64)(cast(*float32)value_pointer).*; }
            else if info.runtime_size == 8 { float_value_as_f64 = cast(float64)(cast(*float64)value_pointer).*; }
            else assert(false);
            float_value_as_u64 := (cast(*u64)*float_value_as_f64).*;
            format := FormatFloat.{ trailing_width = 15 };
            format.value.type = info;
            format.value.value_pointer = value_pointer;
            if float_value_as_f64 >= 0.0 then append(builder, " ");
            print_float(builder, format);
            append(builder, " # ");
            append(builder, "0x");
            print_integer(builder, FormatInt.{ value = float_value_as_u64, base = 16 , minimum_digits = 16});



            case .BOOL;
            if (cast(*bool)value_pointer).* then append(builder, "true"); else append(builder, "false");



            case .STRING;
            the_string := (cast(*string)value_pointer).*;
            append(builder, "\"");
            append(builder, the_string);
            append(builder, "\"");



            case .POINTER;
            pointer_info := cast(*Type_Info_Pointer)info;
            the_pointer := (cast(**void)value_pointer).*;
            successful_pointer_unparse, pointer_unparse_error := unparse_one(builder, pointer_info.pointer_to, the_pointer, depth);
            if !successful_pointer_unparse then return false, pointer_unparse_error;



            case .STRUCT;
            struct_info := cast(*Type_Info_Struct)info;
            default_value := talloc(struct_info.runtime_size);
            if struct_info.initializer then struct_info.initializer(default_value); else memset(default_value, 0, struct_info.runtime_size);
            handled_by_custom_parsing := custom_struct_unparsing();
            if !handled_by_custom_parsing
            {
                added_any_members := false;
                if brackets_on_struct then append(builder, "{");
                max_member_offset_written := -1;
                for member : struct_info.members
                {
                    if !(member.flags & .CONSTANT)
                    {
                        if member.offset_in_bytes > max_member_offset_written
                        {
                            max_member_offset_written = member.offset_in_bytes + max(member.type.runtime_size - 1, 0);
                            member_value_pointer := value_pointer + member.offset_in_bytes;
                            is_default := memcmp(member_value_pointer, default_value + member.offset_in_bytes, member.type.runtime_size) == 0;
                            if !is_default
                            {
                                if !added_any_members
                                {
                                    added_any_members = true;
                                    if brackets_on_struct then append(builder, "\n");
                                }
                                if (member.flags & .USING)
                                {
                                    successful_member_unparse, member_unparse_error := unparse_one(builder, member.type, member_value_pointer, depth, brackets_on_struct = false);
                                    if !successful_member_unparse then return false, member_unparse_error;
                                }
                                else
                                {
                                    append_indentation(builder, depth);
                                    append(builder, member.name);
                                    append(builder, " = ");
                                    successful_member_unparse, member_unparse_error := unparse_one(builder, member.type, member_value_pointer, depth + 1);
                                    if !successful_member_unparse then return false, member_unparse_error;
                                    append(builder, "\n");
                                }
                            }
                        }
                    }
                }
                if brackets_on_struct
                {
                    if added_any_members then append_indentation(builder, depth - 1);
                    append(builder, "}");
                }
            }


                
            case .ARRAY;
            array_info := cast(*Type_Info_Array)info;
            array_view := cast(*Array_View_64)value_pointer;
            print_integer(builder, FormatInt.{ value = array_view.count });
            append(builder, " [\n");
            line_break_every_n_elements := 1;
            if array_info.element_type.type == 
            {
                case .INTEGER; line_break_every_n_elements = 10;
                case .FLOAT;   line_break_every_n_elements = 3;
                case .BOOL;    line_break_every_n_elements = 15;
                case .STRING;  line_break_every_n_elements = 5;
                case .ENUM;    line_break_every_n_elements = 10;
            }
            for 0..array_view.count-1
            {
                if it == 0 || (max(it-1, 0) % line_break_every_n_elements) == (line_break_every_n_elements-1) then append_indentation(builder, depth);
                array_element_value_pointer := array_view.data + (array_info.element_type.runtime_size * it);
                successful_element_unparse, element_unparse_error := unparse_one(builder, array_info.element_type, array_element_value_pointer, depth + 1);
                if !successful_element_unparse then return false, element_unparse_error;
                if it == array_view.count-1 || (it % line_break_every_n_elements) == (line_break_every_n_elements-1) then append(builder, ",\n"); else append(builder, ", ");
            }
            append_indentation(builder, depth - 1);
            append(builder, "]");



            case .ENUM;
            enum_info := cast(*Type_Info_Enum)info;
            enum_value : s64;
            if      info.runtime_size == 1 { enum_value = cast(s64)(cast(*s8) value_pointer).*; }
            else if info.runtime_size == 2 { enum_value = cast(s64)(cast(*s16)value_pointer).*; }
            else if info.runtime_size == 4 { enum_value = cast(s64)(cast(*s32)value_pointer).*; }
            else if info.runtime_size == 8 { enum_value = cast(s64)(cast(*s64)value_pointer).*; }
            else assert(false);
            if (enum_info.enum_type_flags & .FLAGS)
            {
                written_flags := 0;
                for enum_info.values
                {
                    if (enum_value & it) == it
                    {
                        if written_flags != 0 then append(builder, " | "); 
                        append(builder, enum_info.names[it_index]);
                        written_flags |= it;
                    }
                }
                remaining := enum_value & ~written_flags;
                if remaining != 0
                {
                    if written_flags != 0 then append(builder, " | "); 
                    append(builder, "0x");
                    print_integer(builder, FormatInt.{ value = remaining, base = 16 });
                    written_flags |= remaining;
                }
            }
            else
            {
                found := false;
                for enum_info.values
                {
                    if enum_value == it
                    {
                        append(builder, enum_info.names[it_index]);
                        found = true;
                        break;
                    }
                }
                if !found
                {
                    format : FormatInt;
                    format.value.type = enum_info.internal_type;
                    format.value.value_pointer = value_pointer;
                    print_integer(builder, format);
                }
            }



            case .VARIANT;
            variant_info := cast(*Type_Info_Variant)info;
            successful_variant_unparse, variant_unparse_error := unparse_one(builder, variant_info.variant_of, value_pointer, depth);
            if !successful_variant_unparse then return false, variant_unparse_error;



            case .PROCEDURE;            #through;
            case .VOID;                 #through;
            case .OVERLOAD_SET;         #through;
            case .ANY;                  #through;
            case .POLYMORPHIC_VARIABLE; #through;
            case .TYPE;                 #through;
            case .CODE;
            return false, tprint("Requesting unparsing of unsupported type '%'", info.type);
        }

        return true, "";
    }

    info := type_info(Data_Type);
    if info.type != .STRUCT then return false, tprint("Expected the provided type (%) to be a struct and it was % instead", info.name, info.type);

    successful_unparse, unparse_error := unparse_one(builder, info, data, depth = 0, brackets_on_struct = false);
    if !successful_unparse then return false, unparse_error;

    return true, "";
}


