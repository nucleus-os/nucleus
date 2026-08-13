# Topic index

Both vendored pages preserve the canonical Swift.org content with the site-only Jekyll TOC placeholders expanded into linked Markdown tables of contents. The generated heading tables below provide exact line ranges for agent navigation.

## Mixing Swift and C++

Read `mixing-swift-and-cxx.md` with `sed -n '<start>,<end>p'` using these ranges.

| Lines | Section |
| ---: | --- |
| 9–94 | Table of Contents |
| 95–125 | Introduction |
| 126–140 | Overview |
| 141–157 | ↳ Enabling C++ Interoperability |
| 158–175 | ↳ Importing C++ into Swift |
| 176–235 | ↳ Creating a Clang Module |
| 236–295 | ↳ Working with Imported C++ APIs |
| 296–351 | ↳ Exposing Swift APIs to C++ |
| 352–366 | ↳ Source Stability Guarantees for Mixed-Language Codebases |
| 367–372 | Using C++ Types and Functions in Swift |
| 373–388 | ↳ Calling C++ Functions |
| 389–481 | ↳ C++ Structures and Classes are Value Types by Default |
| 482–511 | ↳ Constructing C++ Types from Swift |
| 512–522 | ↳ Accessing Data Members of a C++ Type |
| 523–527 | ↳ Calling C++ Member Functions |
| 528–561 | ↳ ↳ Constant Member Functions Are `nonmutating` |
| 562–581 | ↳ ↳ Constant Member Functions Must Not Mutate the Object |
| 582–612 | ↳ ↳ Member Functions Returning References Are Unsafe by Default |
| 613–641 | ↳ ↳ Overloaded Member Functions |
| 642–646 | ↳ ↳ Virtual Member Functions |
| 647–650 | ↳ ↳ Static Member Functions |
| 651–673 | ↳ ↳ Bool Conversion Operator |
| 674–713 | ↳ Accessing Inherited Members from Swift |
| 714–773 | ↳ Using C++ Enumerations |
| 774–783 | ↳ Using C++ Type Aliases |
| 784–851 | ↳ Using Class Templates |
| 852–875 | Customizing How C++ Maps to Swift |
| 876–904 | ↳ Renaming C++ APIs in Swift |
| 905–936 | ↳ Mapping Getters and Setters to Computed Properties |
| 937–945 | Extending C++ Types in Swift |
| 946–981 | ↳ Conforming C++ Type to Swift Protocol |
| 982–1070 | ↳ Conforming Class Template to Swift Protocol |
| 1071–1117 | ↳ Accessing Private C++ Members in Swift |
| 1118–1138 | Working with C++ Containers |
| 1139–1190 | ↳ Some C++ Containers Are Swift Collections |
| 1191–1204 | ↳ ↳ Performance Constraints of Automatic Collection Conformance |
| 1205–1222 | ↳ ↳ Conformance Rules for Random Access C++ Collections |
| 1223–1253 | ↳ C++ Containers Can Be Converted to Swift Collections |
| 1254–1267 | ↳ ↳ Conformance Rules for `CxxConvertibleToCollection` Protocol |
| 1268–1306 | ↳ Using Associative Container C++ Types in Swift |
| 1307–1322 | ↳ Recommended Approach for Using C++ Containers |
| 1323–1338 | ↳ ↳ Using C++ Containers in Performance Sensitive Swift Code |
| 1339–1340 | ↳ Best Practices for Working with C++ Containers in Swift |
| 1341–1360 | ↳ ↳ Do Not Use C++ Iterators in Swift |
| 1361–1394 | ↳ ↳ Borrow C++ Containers When Calling Swift Functions |
| 1395–1409 | Mapping C++ Types to Swift Reference Types |
| 1410–1432 | ↳ Immortal Reference Types |
| 1433–1475 | ↳ Shared Reference Types |
| 1476–1500 | ↳ ↳ Constructing objects of Shared Reference Types from Swift |
| 1501–1511 | ↳ ↳ Inference of Shared Reference behaviour in Derived Types |
| 1512–1540 | ↳ ↳ Calling conventions when returning Shared Reference Types from C++ to Swift |
| 1541–1578 | ↳ ↳ Calling conventions when passing Shared Reference Types from Swift to C++ |
| 1579–1586 | ↳ ↳ Inheritance and Virtual Member Functions |
| 1587–1603 | ↳ ↳ Exposing C++ Shared Reference Types back from Swift |
| 1604–1666 | ↳ ↳ Bridging Smart Pointers to Shared Reference Types |
| 1667–1671 | ↳ Unsafe Reference Types |
| 1672–1676 | Using C++ Standard Library from Swift |
| 1677–1689 | ↳ Importing C++ Standard Library |
| 1690–1719 | ↳ Using `std::string` |
| 1720–1736 | ↳ Using `std::optional` |
| 1737–1764 | ↳ Using `std::function` |
| 1765–1807 | Working with C++ References and View Types in Swift |
| 1808–1843 | ↳ C++ Types Considered to Be References or View Types by Swift |
| 1844–1911 | ↳ Safely Accessing References with Dependent Lifetime |
| 1912–1922 | ↳ Using Methods That Return References and Views with Independent Lifetime |
| 1923–1943 | ↳ ↳ Annotating Methods Returning Independent References or Views |
| 1944–1949 | ↳ ↳ Annotating C++ Structures or Classes as Self Contained |
| 1950–1965 | Accessing Swift APIs from C++ |
| 1966–1971 | Using Swift Types and Functions from C++ |
| 1972–2000 | ↳ Calling Swift Functions |
| 2001–2015 | ↳ Using Swift Structures In C++ |
| 2016–2050 | ↳ ↳ Creating a Swift Structure in C++ |
| 2051–2107 | ↳ Using Swift Classes in C++ |
| 2108–2161 | ↳ Using Swift Enumerations in C++ |
| 2162–2211 | ↳ ↳ Using Enumerations with Associated Values |
| 2212–2218 | ↳ Calling Swift Methods |
| 2219–2239 | ↳ Accessing Swift Properties in C++ |
| 2240–2246 | Using Swift Standard Library Types from C++ |
| 2247–2290 | ↳ Using Swift `String` in C++ |
| 2291–2352 | ↳ Using Swift `Array` in C++ |
| 2353–2403 | ↳ Using Swift `Optional` in C++ |
| 2404–2408 | Appendix |
| 2409–2426 | ↳ List of Customization Macros in `<swift/bridging>` |
| 2427–2450 | Document Revision History |

Use `rg -n '^##+ ' references/mixing-swift-and-cxx.md` for direct heading lookup.

## Safely Mixing Swift and C/C++

Read `safe-interop.md` with `sed -n '<start>,<end>p'` using these ranges.

| Lines | Section |
| ---: | --- |
| 9–24 | Table of Contents |
| 25–46 | Introduction |
| 47–54 | Overview |
| 55–121 | ↳ Annotating Foreign Types |
| 122–174 | ↳ Annotating C++ APIs |
| 175–263 | Escapability Annotations in Detail |
| 264–394 | Lifetime Annotations in Detail |
| 395–417 | Safe Overloads for Annotated Spans and Pointers |
| 418–441 | ↳ Safe Overloads for C++ `std::span` |
| 442–449 | ↳ Safe Overloads for Pointers |
| 450–510 | ↳ ↳ Annotating Pointers with Bounds Annotations |
| 511–602 | ↳ ↳ Lifetime Annotations for Pointers |
| 603–625 | ↳ ↳ Bounds Annotations using API Notes |
| 626–636 | ↳ ↳ Limitations |

Use `rg -n '^##+ ' references/safe-interop.md` for direct heading lookup.

## Live companion pages

These companion pages are not duplicated here:

- [Supported features and constraints](https://www.swift.org/documentation/cxx-interop/status/)
- [Mixed-language project and build setup](https://www.swift.org/documentation/cxx-interop/project-build-setup/)

Consult them for toolchain/platform support, current limitations, and build-system behavior that may have changed after the vendored revision.
