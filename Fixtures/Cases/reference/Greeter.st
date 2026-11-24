"Smalltalk"
Object subclass: #Greeter
    instanceVariableNames: 'name'
    classVariableNames: ''
    package: 'Glimt'.

Greeter >> hello
    Transcript showln: 'Hej ', name.
