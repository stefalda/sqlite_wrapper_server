import 'package:flutter/material.dart';
import 'package:inject_x/inject_x.dart';
import 'package:sqlite_wrapper_sample/instructions.dart';
import 'package:sqlite_wrapper_sample/models.dart';
import 'package:sqlite_wrapper_sample/services/database_service.dart';
import 'package:sqlite_wrapper_sample/todo_item.dart';

class TodoList extends StatelessWidget {
  const TodoList({super.key});

  @override
  Widget build(BuildContext context) {
    final databaseService = inject<DatabaseService>();
    return Column(
      children: [
        // To-do - COUNT
        StreamBuilder(
          stream: databaseService.getTodoCount(),
          initialData: const [],
          builder: (BuildContext context, AsyncSnapshot snapshot) {
            return Container(
              child: snapshot.hasData
                  ? Text("Count: ${snapshot.data.toString()}")
                  : Container(),
            );
          },
        ),
        // Todos
        StreamBuilder(
          stream: databaseService.getTodos(),
          initialData: const [],
          builder: (BuildContext context, AsyncSnapshot snapshot) {
            if (!snapshot.hasData) {
              return const CircularProgressIndicator();
            }
            final List<Todo> todos = List<Todo>.from(snapshot.data);
            return Expanded(
                //child: SingleChildScrollView(
                child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: ListView.separated(
                separatorBuilder: (BuildContext context, int index) =>
                    const Divider(),
                itemCount: todos.length,
                itemBuilder: (BuildContext context, int index) {
                  final Todo todo = todos[index];
                  return TodoItem(todo);
                },
                //  ),
              ),
            ));
          },
        ),
        const Instructions()
      ],
    );
  }
}
