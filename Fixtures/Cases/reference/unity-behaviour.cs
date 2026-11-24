using UnityEngine;

public class Spinner : MonoBehaviour
{
    [SerializeField] private float speed = 90f;

    void Update()
    {
        transform.Rotate(Vector3.up, speed * Time.deltaTime);
    }
}
